import CoreVideo
import Foundation
import Metal
import simd
import Testing
@testable import RAVEMedia

/// Silhouette fidelity of the realtime refiner's output, as the warp reads it.
/// The warp samples depth bilinearly, so the displaced silhouette sits where
/// that bilinear field crosses halfway between subject and background. A
/// hard-stepped map at model resolution puts that crossing on depth texel
/// boundaries (~3.7 video px at 1080p) and a smooth edge stairsteps; the
/// guided upsample has to pull it back onto the image edge.
@Suite("Realtime depth edges")
struct RealtimeDepthEdgeTests {
    static let videoWidth = 1920, videoHeight = 1080
    static let depthWidth = 518, depthHeight = 392
    // A disc in video pixels: its edge sweeps every slope.
    static let center = SIMD2<Float>(960, 540)
    static let radius: Float = 300

    @Test func refinedSilhouetteFollowsTheImageEdge() throws {
        guard let metal = RAVEMediaMetal.shared else { return }
        let device = metal.device
        let queue = try #require(device.makeCommandQueue())
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let textureCache = try #require(cache)
        let refiner = try #require(RealtimeDepthRefiner(device: device, commandQueue: queue, textureCache: textureCache))

        let frame = try #require(Self.discFrame())
        let raw = try #require(Self.discDepth(device: device))
        var out: MTLTexture?
        // A few frames, so the lock and the EMA are past their first-frame path.
        for i in 0..<4 {
            out = refiner.refine(raw: raw, frame: frame, frameSeconds: Double(i) / 30)
        }
        let depth = try #require(out)
        let (w, h, values) = try #require(Self.read(depth, device: device, queue: queue))

        let uv = CoreMLDepthProvider.letterboxUVTransform(
            videoWidth: Self.videoWidth, videoHeight: Self.videoHeight, depthWidth: w, depthHeight: h
        )
        // Bilinear read at a video pixel, the way the warp samples the map.
        func sample(_ x: Float, _ y: Float) -> Float {
            let u = (x + 0.5) / Float(Self.videoWidth) * uv.scale.x + uv.offset.x
            let v = (y + 0.5) / Float(Self.videoHeight) * uv.scale.y + uv.offset.y
            let fx = u * Float(w) - 0.5, fy = v * Float(h) - 0.5
            let x0 = max(0, min(w - 1, Int(fx.rounded(.down)))), y0 = max(0, min(h - 1, Int(fy.rounded(.down))))
            let x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
            let tx = max(0, min(1, fx - Float(x0))), ty = max(0, min(1, fy - Float(y0)))
            let a = values[y0 * w + x0] * (1 - tx) + values[y0 * w + x1] * tx
            let b = values[y1 * w + x0] * (1 - tx) + values[y1 * w + x1] * tx
            return a * (1 - ty) + b * ty
        }
        let fg = sample(Self.center.x, Self.center.y)
        let bg = sample(Self.center.x + Self.radius * 1.5, Self.center.y)
        let half = (fg + bg) / 2
        #expect(fg > bg)

        // Right-hand edge, every video row across the disc's middle band
        // (slopes from vertical to 60°): the crossing's distance from the
        // true circle.
        var errors: [Float] = []
        let span = Int(Self.radius * 0.85)
        for dy in -span...span {
            let y = Self.center.y + Float(dy)
            let truth = Self.center.x + (Self.radius * Self.radius - Float(dy * dy)).squareRoot()
            var x = truth - 20
            var previous = sample(x, y)
            var crossing: Float?
            while x < truth + 20 {
                let next = sample(x + 0.25, y)
                if previous >= half, next < half {
                    crossing = x + 0.25 * (previous - half) / max(previous - next, 1e-6)
                    break
                }
                previous = next
                x += 0.25
            }
            errors.append(abs((crossing ?? (truth + 20)) - truth))
        }
        let rms = (errors.reduce(0) { $0 + $1 * $1 } / Float(errors.count)).squareRoot()
        let worst = errors.max() ?? 0
        // Stairstepping is the row-to-row part of the error: what's left after
        // a 9-row moving average (a steady offset reads as a slightly
        // smaller subject, not as steps).
        let wobble = (4..<(errors.count - 4)).map { i -> Float in
            let local = errors[(i - 4)...(i + 4)].reduce(0, +) / 9
            return errors[i] - local
        }
        let wobbleRMS = (wobble.reduce(0) { $0 + $1 * $1 } / Float(wobble.count)).squareRoot()
        print(String(format: "realtime silhouette error vs image edge: rms %.2f px, worst %.2f px, row-to-row wobble %.2f px (map %dx%d)",
                     rms, worst, wobbleRMS, w, h))
        // At 1× the crossing wanders across a whole depth texel (~3.7 px).
        #expect(rms < 1.0)
        #expect(worst < 2.0)
        #expect(wobbleRMS < 0.5)
    }

    /// Anti-aliased white disc on grey, BGRA, full HD.
    static func discFrame() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(nil, videoWidth, videoHeight, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<videoHeight {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<videoWidth {
                let d = simd_length(SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) - center)
                let coverage = max(0, min(1, radius - d + 0.5))
                let v = UInt8((0.25 + 0.7 * coverage) * 255)
                row[x * 4] = v; row[x * 4 + 1] = v; row[x * 4 + 2] = v; row[x * 4 + 3] = 255
            }
        }
        return pb
    }

    /// The model's view of it: a hard near/far step on the depth texel lattice.
    static func discDepth(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: depthWidth, height: depthHeight, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let uv = CoreMLDepthProvider.letterboxUVTransform(
            videoWidth: videoWidth, videoHeight: videoHeight, depthWidth: depthWidth, depthHeight: depthHeight
        )
        var values = [Float16](repeating: 0, count: depthWidth * depthHeight)
        for j in 0..<depthHeight {
            for i in 0..<depthWidth {
                let u = (Float(i) + 0.5) / Float(depthWidth), v = (Float(j) + 0.5) / Float(depthHeight)
                let video = SIMD2((u - uv.offset.x) / uv.scale.x * Float(videoWidth), (v - uv.offset.y) / uv.scale.y * Float(videoHeight))
                values[j * depthWidth + i] = simd_length(video - center) < radius ? 1.0 : 0.2
            }
        }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, depthWidth, depthHeight), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: depthWidth * 2)
        }
        return texture
    }

    static func read(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) -> (Int, Int, [Float])? {
        let w = texture.width, h = texture.height
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder(),
              let bytes = device.makeBuffer(length: w * h * 2, options: .storageModeShared) else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: bytes, destinationOffset: 0,
                  destinationBytesPerRow: w * 2, destinationBytesPerImage: w * h * 2)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let ptr = bytes.contents().bindMemory(to: Float16.self, capacity: w * h)
        return (w, h, (0..<(w * h)).map { Float(ptr[$0]) })
    }
}
