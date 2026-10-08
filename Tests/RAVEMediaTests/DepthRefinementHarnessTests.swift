import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import Testing
@testable import RAVEMedia

/// Measurement harness, not a regular test: runs the shipped realtime depth
/// path and the refined one over a frame sequence with the real model, on the
/// GPU, and prints how much a background patch's displayed depth moves.
/// Needs a Metal library (run under `xcodebuild test`, not `swift test`) and:
///   DEPTH_HARNESS_MODEL   path to a depth .mlpackage / .mlmodelc
///   DEPTH_HARNESS_FRAMES  directory of PNG frames, played at 30 fps
///   DEPTH_HARNESS_PATCH   background patch "x0,y0,x1,y1" in frame UV (optional)
/// (`TEST_RUNNER_`-prefixed when passed through xcodebuild.)
@Suite("Depth refinement harness")
struct DepthRefinementHarnessTests {
    @Test func measureBackgroundStability() throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["DEPTH_HARNESS_MODEL"], let framesPath = env["DEPTH_HARNESS_FRAMES"],
              let metal = RAVEMediaMetal.shared else { return }
        let patch = (env["DEPTH_HARNESS_PATCH"] ?? "0.03,0.03,0.25,0.35")
            .split(separator: ",").compactMap { Float($0) }
        let device = metal.device
        let modelURL = URL(fileURLWithPath: modelPath)
        let legacyProvider = try #require(CoreMLDepthProvider(device: device, modelURL: modelURL))
        let refinedProvider = try #require(CoreMLDepthProvider(device: device, modelURL: modelURL))
        #expect(refinedProvider.supportsRefinement)

        let frames = try FileManager.default.contentsOfDirectory(atPath: framesPath)
            .filter { $0.hasSuffix(".png") }.sorted()
            .map { URL(fileURLWithPath: framesPath).appendingPathComponent($0) }
        var legacy: [Float] = []
        var refined: [Float] = []
        var refineMs: [Double] = []
        var legacyMs: [Double] = []
        for (i, url) in frames.enumerated() {
            let frame = try #require(Self.pixelBuffer(from: url))
            let legacyStart = CFAbsoluteTimeGetCurrent()
            let l = try #require(legacyProvider.depth(for: frame))
            legacyMs.append((CFAbsoluteTimeGetCurrent() - legacyStart) * 1000)
            legacy.append(Self.patchMean(l, patch: patch, budget: .legacy, device: device))
            let start = CFAbsoluteTimeGetCurrent()
            let r = try #require(refinedProvider.refinedDepth(for: frame, frameSeconds: Double(i) / 30))
            refineMs.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            refined.append(Self.patchMean(r, patch: patch, budget: .studio, device: device))
            if i == frames.count - 1 {
                let subject: [Float] = [0.55, 0.7, 0.8, 0.95]
                print(String(format: "harness last frame subject patch: legacy %.3f, refined %.3f; background: legacy %.3f, refined %.3f",
                             Self.patchMean(l, patch: subject, budget: .legacy, device: device),
                             Self.patchMean(r, patch: subject, budget: .studio, device: device),
                             legacy.last ?? 0, refined.last ?? 0))
            }
            if env["DEPTH_HARNESS_TRACE"] != nil, let d = refinedProvider.refinementDiagnostics {
                print(String(format: "harness f%02d anchored=%d cut=%d a=%.3f b=%.3f", i, d.anchored ? 1 : 0, d.cut ? 1 : 0, d.mapping.a, d.mapping.b))
            }
        }
        func std(_ v: [Float]) -> Float {
            let m = v.reduce(0, +) / Float(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(v.count)).squareRoot()
        }
        func range(_ v: [Float]) -> Float { (v.max() ?? 0) - (v.min() ?? 0) }
        print("harness frames=\(frames.count)")
        print("harness legacy  patch: \(legacy.map { String(format: "%.3f", $0) }.joined(separator: " "))")
        print("harness refined patch: \(refined.map { String(format: "%.3f", $0) }.joined(separator: " "))")
        print(String(format: "harness legacy  std %.4f range %.4f", std(legacy), range(legacy)))
        print(String(format: "harness refined std %.4f range %.4f", std(refined), range(refined)))
        func median(_ v: [Double]) -> Double {
            let sorted = v.dropFirst(3).sorted()
            return sorted.isEmpty ? .nan : sorted[sorted.count / 2]
        }
        print(String(format: "harness call median (inference + post, this Mac): legacy %.1f ms, refined %.1f ms",
                     median(legacyMs), median(refineMs)))
        func maxStep(_ v: [Float]) -> Float { (1..<v.count).map { abs(v[$0] - v[$0 - 1]) }.max() ?? 0 }
        print(String(format: "harness max frame-to-frame step: legacy %.3f, refined %.3f", maxStep(legacy), maxStep(refined)))
    }

    /// Mean displayed depth (after the budget) over a UV patch of the map,
    /// read back on the CPU.
    static func patchMean(_ texture: MTLTexture, patch: [Float], budget: DepthBudget, device: MTLDevice) -> Float {
        let w = texture.width, h = texture.height
        guard texture.pixelFormat == .r16Float, let queue = device.makeCommandQueue(),
              let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder(),
              let bytes = device.makeBuffer(length: w * h * 2, options: .storageModeShared) else { return .nan }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: bytes, destinationOffset: 0,
                  destinationBytesPerRow: w * 2, destinationBytesPerImage: w * h * 2)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let ptr = bytes.contents().bindMemory(to: Float16.self, capacity: w * h)
        // The model letterboxes: patch UVs are in frame space, the depth map's
        // content region is centered. The harness frames are 4:3 like the
        // model's 518×392 input, so the transform is close to identity.
        let x0 = Int(patch[0] * Float(w)), y0 = Int(patch[1] * Float(h))
        let x1 = Int(patch[2] * Float(w)), y1 = Int(patch[3] * Float(h))
        var sum: Float = 0
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                sum += budget.apply(Float(ptr[y * w + x]))
                n += 1
            }
        }
        return sum / Float(max(n, 1))
    }

    static func pixelBuffer(from url: URL) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
