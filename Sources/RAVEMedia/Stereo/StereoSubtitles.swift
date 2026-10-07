/*
 RAVEMedia - subtitles drawn into the stereo picture.

 SwiftUI drawn over the stereo video plane never shows in front of it, and a
 panel beside the picture sits at the window's depth while the picture's
 content reads nearer or farther (device, 2026-10-07: from an angle the
 picture covered a band hung under the window). So the pump draws subtitles
 into both eye images, the way 3D releases do: the same text in each eye,
 shifted sideways in opposite directions so it reads at a chosen depth in
 front of whatever the picture shows behind it.

 Where that depth comes from:
 - Fake 3D: the warp's own formula, `(depth - convergence) * depthStrength`
   over depth saturated to [0, 1], bounds every pixel's shift at
   `(1 - convergence) * depthStrength`. The text goes just in front of that
   bound, so nothing the warp makes can come out in front of it.
 - Live 3D (a packed pair): nothing is known about the source's stereo, so
   the two eyes are matched in the region behind the text
   (`stereoSubtitleMatch`), and the text goes just in front of the nearest
   of what it finds.

 A cue keeps its depth while it shows, moving only forward (nearer content
 arriving behind it), never back: text drifting in depth is uncomfortable
 to read. A new cue starts at the depth measured for it. The host's
 `depthOffset` moves all of it nearer or farther from there.

 Text comes in as images the host renders (the host owns the styling), at
 the size it should cover in an eye of a given height. Its colour is
 written in the picture's own transfer function: an HDR (PQ or HLG) picture
 puts the text's white at a set luminance instead of the signal's maximum,
 which for PQ is 10,000 nits.
 */

#if os(visionOS)

import CoreGraphics
import CoreVideo
import Metal
import os
import QuartzCore

/// One block of subtitle text, rendered by the host.
public struct RAVEStereoSubtitle: @unchecked Sendable {
    public enum Placement: Sendable { case top, bottom }

    /// Premultiplied, in sRGB. White text on a dark plate is what the
    /// colour handling is written for; other colours pass through in SDR.
    public let image: CGImage
    public let placement: Placement
    /// The eye height, in pixels, `image` was rendered for: it covers
    /// `image.width × image.height` pixels of an eye this tall, and is scaled
    /// for any other.
    public let referenceEyeHeight: CGFloat

    public init(image: CGImage, placement: Placement, referenceEyeHeight: CGFloat) {
        self.image = image
        self.placement = placement
        self.referenceEyeHeight = referenceEyeHeight
    }
}

/// What the host wants drawn into the stereo picture. Nil on the engine
/// means subtitles are off; a frame with nothing to show means a track is
/// on between cues, which keeps live 3D measuring so the next cue has a
/// depth ready.
public struct RAVEStereoSubtitleFrame: Equatable {
    /// Changes whenever `render` would draw something else.
    public var version: Int
    /// The luminance of the text's white on an HDR picture.
    public var hdrWhiteNits: Double
    /// Moves the text away from the depth chosen for it, as each eye's shift
    /// in fractions of the eye's width: positive is farther, negative nearer.
    /// Applied as is, so it can put text behind the content it would cover.
    public var depthOffset: Double
    /// Draws the cues showing for an eye of the given size, in pixels. Called
    /// on the main actor when the frame changes and when the eye size does.
    public var render: @MainActor (_ eyeSize: CGSize) -> [RAVEStereoSubtitle]

    /// BT.2408's reference white for graphics in an HDR programme.
    public static let defaultHDRWhiteNits: Double = 203

    public init(version: Int, hdrWhiteNits: Double = defaultHDRWhiteNits, depthOffset: Double = 0,
                render: @escaping @MainActor (_ eyeSize: CGSize) -> [RAVEStereoSubtitle]) {
        self.version = version
        self.hdrWhiteNits = hdrWhiteNits
        self.depthOffset = depthOffset
        self.render = render
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.hdrWhiteNits == rhs.hdrWhiteNits && lhs.depthOffset == rhs.depthOffset
    }
}

/// The pump-side form of a subtitle frame: textures, ready to draw.
struct StereoSubtitleOverlay: @unchecked Sendable {
    struct Item {
        let texture: MTLTexture
        let pixelSize: CGSize
        let referenceEyeHeight: CGFloat
        let placement: RAVEStereoSubtitle.Placement
    }

    let items: [Item]
    let hdrWhiteNits: Float
    /// Per-eye shift in eye UV taken off the chosen depth (positive = farther).
    let depthOffset: Float
    /// Bumped per overlay handed to the pump: a new one is a new cue.
    let generation: Int

    /// Uploads each image. Runs on the caller's thread; subtitle images are a
    /// few hundred kilobytes and change a few times a minute.
    init?(subtitles: [RAVEStereoSubtitle], hdrWhiteNits: Double, depthOffset: Double,
          generation: Int, device: MTLDevice) {
        var items: [Item] = []
        for subtitle in subtitles {
            guard let texture = Self.makeTexture(subtitle.image, device: device) else { return nil }
            items.append(Item(texture: texture,
                              pixelSize: CGSize(width: subtitle.image.width, height: subtitle.image.height),
                              referenceEyeHeight: subtitle.referenceEyeHeight,
                              placement: subtitle.placement))
        }
        self.items = items
        self.hdrWhiteNits = Float(hdrWhiteNits)
        self.depthOffset = Float(depthOffset)
        self.generation = generation
    }

    /// Redrawn into a known layout (premultiplied RGBA, sRGB) rather than
    /// trusting the image's own, which a renderer may make wide-gamut or
    /// 16-bit.
    private static func makeTexture(_ image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }
}

/// CPU mirror of the Metal `SubtitleQuadUniforms`.
private struct SubtitleQuadUniforms {
    /// Top-left origin and size of the text in eye UV, before the shift.
    var rectOrigin: SIMD2<Float>
    var rectSize: SIMD2<Float>
    /// This eye's horizontal shift in eye UV (positive moves right).
    var shift: Float
    /// 0 = SDR (written as is), 1 = PQ, 2 = HLG.
    var transfer: Float
    var whiteNits: Float
    var padding: Float = 0
}

/// CPU mirror of the Metal `SubtitleMatchParams`.
private struct SubtitleMatchParams {
    var regionOrigin: SIMD2<Float>
    var regionSize: SIMD2<Float>
    var patchGrid: SIMD2<UInt32>
    /// Pixels between disparity candidates and between patch samples.
    var candidateStep: Int32
    var sampleStep: Int32
}

/// Draws subtitles into a pump's eye images and decides their depth. Pump
/// queue only, apart from `setOverlay`.
final class StereoSubtitleCompositor: @unchecked Sendable {
    /// Distance in front of the nearest possible fake-3D content, as a
    /// fraction of the warp's depth strength: at the default strength and a
    /// window a metre or so wide, a few centimetres. Untuned on device.
    static let fakeDepthMargin: Float = 0.15
    /// The same for a packed pair, per eye in eye UV (≈ the fake-3D margin at
    /// the default strength). Untuned on device.
    static let packedDepthMargin: Float = 0.0012
    /// Thread count per patch in the match kernel, so the number of disparity
    /// candidates; must match `stereoSubtitleMatch`'s threadgroup arrays.
    private static let candidateCount = 128
    private static let patchColumns = 16
    private static let patchRows = 4
    /// Match every few frames: content depth behind a cue changes slower than
    /// the frame rate, and the match takes the eyes' finished images.
    private static let matchInterval = 3
    /// Fraction of the gap to a nearer target closed per frame (≈ 0.15 s to
    /// settle at 60 fps): fast enough that content never stays in front of
    /// the text, slow enough not to jump.
    private static let approachRate: Float = 0.25

    private let device: MTLDevice
    private let quadPipeline: MTLRenderPipelineState
    private let matchPipeline: MTLComputePipelineState
    private let matchResults: MTLBuffer

    private let overlayLock = NSLock()
    private var pendingOverlay: StereoSubtitleOverlay??

    // Pump queue only.
    private var overlay: StereoSubtitleOverlay?
    private var shownGeneration = -1
    /// This eye's shift in eye UV for the text showing now.
    private var shift: Float = 0
    /// Packed pair: the per-eye shift the last match asked for.
    private var measuredShift: Float?
    private var framesSinceMatch = 0
    /// The cue showing has not been matched behind yet.
    private var snapsToNextMatch = false
    private var matchEncoded = false
    private var matchEyeWidth = 0

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let vertex = library.makeFunction(name: "stereoSubtitleVertex"),
              let fragment = library.makeFunction(name: "stereoSubtitleFragment"),
              let match = library.makeFunction(name: "stereoSubtitleMatch"),
              let matchPipeline = try? device.makeComputePipelineState(function: match),
              let results = device.makeBuffer(
                  length: Self.patchColumns * Self.patchRows * MemoryLayout<SIMD2<Float>>.stride,
                  options: .storageModeShared
              ) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        // Premultiplied source over the eye image.
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let quadPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.quadPipeline = quadPipeline
        self.matchPipeline = matchPipeline
        self.matchResults = results
    }

    /// Any thread. Nil turns subtitles off.
    func setOverlay(_ overlay: StereoSubtitleOverlay?) {
        overlayLock.lock()
        pendingOverlay = .some(overlay)
        overlayLock.unlock()
    }

    /// Picks up an overlay handed over since the last frame.
    private func adoptPendingOverlay() {
        overlayLock.lock()
        let pending = pendingOverlay
        pendingOverlay = nil
        overlayLock.unlock()
        if let pending { overlay = pending }
    }

    /// Encodes the subtitle work for one frame into `commandBuffer`, after
    /// both eyes have been drawn: a disparity match behind the text (packed
    /// pairs, every few frames) and the text itself. `didComplete` must run
    /// once the buffer has finished.
    func encode(left: MTLTexture, right: MTLTexture, packed: Bool,
                maxContentShift: Float, depthStrength: Float,
                transfer: Float, commandBuffer: MTLCommandBuffer) {
        adoptPendingOverlay()
        matchEncoded = false
        guard let overlay else {
            measuredShift = nil
            shownGeneration = -1
            snapsToNextMatch = false
            return
        }
        let eyeSize = SIMD2(Float(left.width), Float(left.height))
        let rects = overlay.items.map { rect(for: $0, eyeSize: eyeSize) }
        let isNewCue = overlay.generation != shownGeneration
        shownGeneration = overlay.generation

        if packed {
            framesSinceMatch += 1
            // A new cue is matched behind its own text at once, and takes
            // that answer whichever way it moves (`snapsToNextMatch`).
            if isNewCue { snapsToNextMatch = true }
            if isNewCue || framesSinceMatch >= Self.matchInterval || measuredShift == nil {
                framesSinceMatch = 0
                encodeMatch(left: left, right: right, behind: rects, commandBuffer: commandBuffer)
            }
        }

        let target = packed
            ? (measuredShift ?? Self.packedDepthMargin)
            : max(0, maxContentShift) + Self.fakeDepthMargin * depthStrength
        if isNewCue || overlay.items.isEmpty {
            // Nothing on screen to keep steady.
            shift = target
        } else if target > shift {
            shift += (target - shift) * Self.approachRate
        }

        guard !overlay.items.isEmpty else { return }
        for (texture, eyeSign) in [(left, Float(1)), (right, Float(-1))] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(quadPipeline)
            for (item, rect) in zip(overlay.items, rects) {
                // Crossed disparity reads as in front: the left eye's copy
                // moves right, the right eye's left.
                var uniforms = SubtitleQuadUniforms(
                    rectOrigin: SIMD2(Float(rect.minX), Float(rect.minY)),
                    rectSize: SIMD2(Float(rect.width), Float(rect.height)),
                    shift: eyeSign * (shift - overlay.depthOffset), transfer: transfer, whiteNits: overlay.hdrWhiteNits
                )
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SubtitleQuadUniforms>.size, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SubtitleQuadUniforms>.size, index: 0)
                encoder.setFragmentTexture(item.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            encoder.endEncoding()
        }
    }

    /// Reads back the match, if one ran.
    func didComplete() {
        guard matchEncoded, matchEyeWidth > 0 else { return }
        matchEncoded = false
        let count = Self.patchColumns * Self.patchRows
        let results = matchResults.contents().bindMemory(to: SIMD2<Float>.self, capacity: count)
        var disparities: [Float] = []
        for index in 0..<count where results[index].y > 0.5 {
            disparities.append(results[index].x)
        }
        // Too few textured, unambiguous patches (a dark or flat scene): keep
        // the last answer rather than guess.
        guard disparities.count >= max(3, count / 10) else { return }
        disparities.sort()
        // The near end, not the extreme: one mismatched patch shouldn't throw
        // the text forward.
        let nearest = disparities[Int(Float(disparities.count - 1) * 0.9)]
        // Total crossed disparity, in pixels → each eye's half, in eye UV.
        let measured = nearest / Float(matchEyeWidth) / 2 + Self.packedDepthMargin
        measuredShift = measured
        if snapsToNextMatch {
            snapsToNextMatch = false
            shift = measured
        }
    }

    /// Where an item sits in an eye, in eye UV (origin top left): centred,
    /// 5 % of the height in from its edge, as on the flat players.
    private func rect(for item: StereoSubtitleOverlay.Item, eyeSize: SIMD2<Float>) -> CGRect {
        let scale = CGFloat(eyeSize.y) / max(item.referenceEyeHeight, 1)
        let width = item.pixelSize.width * scale / CGFloat(eyeSize.x)
        let height = item.pixelSize.height * scale / CGFloat(eyeSize.y)
        let y: CGFloat = item.placement == .top ? 0.05 : 0.95 - height
        return CGRect(x: (1 - width) / 2, y: y, width: width, height: height)
    }

    private func encodeMatch(left: MTLTexture, right: MTLTexture, behind rects: [CGRect],
                             commandBuffer: MTLCommandBuffer) {
        // Behind the text, a little beyond it vertically; the band subtitles
        // usually use between cues, so the next one starts with a depth.
        var region = rects.reduce(CGRect.null) { $0.union($1) }
        if region.isNull {
            region = CGRect(x: 0.1, y: 0.72, width: 0.8, height: 0.24)
        } else {
            region = region.insetBy(dx: 0, dy: -region.height * 0.25)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard !region.isEmpty, let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let width = Float(left.width), height = Float(left.height)
        // A candidate per pixel at 1920 wide covers ±64 px (±3.3 % of the
        // width), the range a comfortable 3D release stays within.
        let step = Int32(max(1, (width / 1920).rounded()))
        var params = SubtitleMatchParams(
            regionOrigin: SIMD2(Float(region.minX) * width, Float(region.minY) * height),
            regionSize: SIMD2(Float(region.width) * width, Float(region.height) * height),
            patchGrid: SIMD2(UInt32(Self.patchColumns), UInt32(Self.patchRows)),
            candidateStep: step, sampleStep: step * 2
        )
        encoder.setComputePipelineState(matchPipeline)
        encoder.setTexture(left, index: 0)
        encoder.setTexture(right, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<SubtitleMatchParams>.size, index: 0)
        encoder.setBuffer(matchResults, offset: 0, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: Self.patchColumns, height: Self.patchRows, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.candidateCount, height: 1, depth: 1)
        )
        encoder.endEncoding()
        matchEncoded = true
        matchEyeWidth = left.width
    }

    /// The shader's transfer mode for a frame's transfer-function tag.
    static func transferMode(of frame: CVPixelBuffer) -> Float {
        guard let tag = CVBufferGetAttachment(frame, kCVImageBufferTransferFunctionKey, nil)?.takeUnretainedValue() else {
            return 0
        }
        if CFEqual(tag, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) { return 1 }
        if CFEqual(tag, kCVImageBufferTransferFunction_ITU_R_2100_HLG) { return 2 }
        return 0
    }
}

#endif
