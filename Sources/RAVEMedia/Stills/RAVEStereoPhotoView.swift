#if os(visionOS)
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Observation
import Metal
import RealityKit
import SwiftUI
import VergenceApple
import VergenceCore

/// A still presented through the same tagged-eye surface as stereo video.
/// The flat sizing/fallback layer is owned by the caller; `onReady` tells it
/// when to yield to the stereo plane, including after navigation or failure.
public struct RAVEStereoPhotoView: View {
    /// The image is on the window surface, so input needn't sit 64 pt forward
    /// as it did for the old relief mesh.
    public nonisolated static let inputTargetZ: CGFloat = 4
    let image: CGImage
    let depth: StillDepthMap
    let contentID: AnyHashable
    var adjustments: RAVEAIDepthPhotoView.Adjustments
    var cornerRadius: CGFloat
    var isFlipped: Bool
    var opacity: Double
    var fadeDuration: TimeInterval
    var onReady: (Bool) -> Void
    /// Debug A/B only until the disconnected renderer is checked on device.
    @AppStorage("aiPhotoSeparateBoundaries") private var separatesBoundaries = false
    @State private var presentation = Presentation()
    @Environment(\.physicalMetrics) private var metrics
    @Environment(\.scenePhase) private var scenePhase

    public init(image: CGImage, depth: StillDepthMap, contentID: AnyHashable,
                adjustments: RAVEAIDepthPhotoView.Adjustments = .neutral,
                cornerRadius: CGFloat = 0, isFlipped: Bool = false, opacity: Double = 1, fadeDuration: TimeInterval = 0.25,
                onReady: @escaping (Bool) -> Void = { _ in }) {
        self.image = image; self.depth = depth; self.contentID = contentID
        self.adjustments = adjustments; self.cornerRadius = cornerRadius
        self.isFlipped = isFlipped; self.opacity = opacity; self.fadeDuration = fadeDuration; self.onReady = onReady
    }

    public var body: some View {
        GeometryReader { geometry in
            let widthMeters = Float(metrics.convert(geometry.size.width, to: .meters))
            let strength = Float(Pseudo3DSettings.default.depthStrength) / max(widthMeters, 1)
            let key = Key(content: contentID, image: ObjectIdentifier(image), depth: depth.id, adjustments: adjustments,
                          strength: Int((strength * 100_000).rounded()), boundaries: separatesBoundaries, mirror: isFlipped)
            FadingPlane(entity: presentation.entity,
                aspect: Float(image.width) / Float(image.height), squareCorners: cornerRadius == 0,
                opacity: Float(opacity), onAttach: { [presentation] in
                    Task { await presentation.resume() }
                })
                .animation(.easeInOut(duration: fadeDuration), value: opacity)
                .task(id: key) {
                    if presentation.matches(key), presentation.ready {
                        await presentation.resume()
                        return
                    }
                    if !presentation.ready { onReady(false) }
                    // Coalesce slider and window-size changes. A prepared picture
                    // stays visible while a replacement is built.
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    await presentation.load(image: image, depth: depth, adjustments: adjustments,
                                            strength: strength, separatesBoundaries: separatesBoundaries, mirror: isFlipped, key: key, onReady: onReady)
                }
        }
        .allowsHitTesting(false)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await presentation.resume() } }
        }
    }

    /// Numeric render diagnostics for the host's debug surface (no pixels).
    public static func diagnosticState() -> [[String: String]] {
        Presentation.live.allObjects.map { p in
            let b = p.entity.visualBounds(relativeTo: nil)
            return ["ready": String(p.ready), "status": String(p.renderer.status.rawValue),
                    "errorCode": String((p.renderer.error as NSError?)?.code ?? 0),
                    "clockRate": String(p.synchronizer.rate),
                    "clockTime": String(p.synchronizer.currentTime().seconds),
                    "requiresFlush": String(p.renderer.requiresFlushToResumeDecoding),
                    "acceptsData": String(p.renderer.isReadyForMoreMediaData),
                    "componentOpacity": String(p.entity.components[OpacityComponent.self]?.opacity ?? -1),
                    "scale": String(describing: p.entity.scale),
                    "position": String(describing: p.entity.position),
                    "boundsCenter": String(describing: b.center),
                    "boundsExtents": String(describing: b.extents)]
        }
    }

    /// OpacityComponent isn't driven by SwiftUI's opacity modifier. An
    /// animatable value feeds it on every transition step instead.
    nonisolated private struct FadingPlane: View, Animatable {
        let entity: Entity
        let aspect: Float
        let squareCorners: Bool
        var opacity: Float
        let onAttach: @MainActor @Sendable () -> Void
        var animatableData: Float {
            get { opacity }
            set { opacity = newValue }
        }
        @MainActor var body: some View {
            RAVEVideoPlaneView(entity: entity, aspect: aspect, squareCorners: squareCorners,
                              opacity: opacity, takesInput: false, placement: .windowSurface, onAttach: { onAttach() })
        }
    }

    fileprivate struct Key: Hashable {
        let content: AnyHashable
        let image: ObjectIdentifier
        let depth: UUID
        let adjustments: RAVEAIDepthPhotoView.Adjustments
        let strength: Int
        let boundaries: Bool
        let mirror: Bool
    }

    @MainActor @Observable fileprivate final class Presentation {
        static let live = NSHashTable<RAVEStereoPhotoView.Presentation>.weakObjects()
        let renderer = AVSampleBufferVideoRenderer()
        @ObservationIgnored let synchronizer = AVSampleBufferRenderSynchronizer()
        let entity = Entity()
        var ready = false
        private var generation = 0
        @ObservationIgnored private var cachedKey: RAVEStereoPhotoView.Key?
        @ObservationIgnored private var cachedFrame: RAVEStereoPhotoView.Frame?
        @ObservationIgnored private var statusObservation: NSKeyValueObservation?
        @ObservationIgnored private var readiness: ((Bool) -> Void)?
        init() {
            var component = VideoPlayerComponent(videoRenderer: renderer)
            component.desiredViewingMode = .stereo
            component.isPassthroughTintingEnabled = false
            entity.components.set(component)
            synchronizer.addRenderer(renderer)
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
            synchronizer.setRate(1, time: .zero)
            statusObservation = renderer.observe(\.status, options: [.new]) { [weak self] renderer, _ in
                guard renderer.status == .failed else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.ready = false
                    self.readiness?(false)
                }
            }
        }
        isolated deinit { renderer.flush() }

        func matches(_ key: RAVEStereoPhotoView.Key) -> Bool { cachedKey == key && cachedFrame != nil }

        /// RealityView can reattach when ornaments change. Keep/re-enqueue the
        /// same eyes rather than clearing a valid still or rerunning the model.
        func resume() async {
            guard let frame = cachedFrame else { return }
            let token = generation
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                await renderer.flush(removingDisplayedImage: false)
                guard token == generation else { return }
            }
            enqueue(frame)
            if renderer.status == .rendering { ready = true; readiness?(true) }
        }

        private func enqueue(_ frame: RAVEStereoPhotoView.Frame) {
            let tagged = frame.sample.content
            let sample = CMReadySampleBuffer(taggedBuffers: tagged,
                formatDescription: CMTaggedBufferGroupFormatDescription(taggedBuffers: tagged),
                presentationTimeStamp: synchronizer.currentTime() + CMTime(value: 1, timescale: 30),
                duration: CMTime(value: 86_400, timescale: 1))
            sample.withUnsafeSampleBuffer { renderer.enqueue($0) }
        }

        func clear() {
            generation += 1
            ready = false
            renderer.flush(removingDisplayedImage: true)
            readiness = nil
            cachedKey = nil
            cachedFrame = nil
        }
        func load(image: CGImage, depth: StillDepthMap, adjustments: RAVEAIDepthPhotoView.Adjustments,
                  strength: Float, separatesBoundaries: Bool, mirror: Bool, key: RAVEStereoPhotoView.Key, onReady: @escaping (Bool) -> Void) async {
            Self.live.add(self)
            generation += 1
            let token = generation
            readiness = onReady
            do {
                let frame = try await RAVEStereoPhotoView.Worker.shared.prepareStill(image: image, depth: depth,
                    adjustments: adjustments, strength: strength, separatesBoundaries: separatesBoundaries, mirror: mirror)
                guard !Task.isCancelled, token == generation else { return }
                if renderer.status == .failed {
                    await renderer.flush(removingDisplayedImage: true)
                    guard !Task.isCancelled, token == generation else { return }
                }
                enqueue(frame)
                for _ in 0..<75 {
                    try await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled, token == generation else { return }
                    guard renderer.status != .failed else { throw StillStereoRenderer.Failure.unavailable }
                    if renderer.status == .rendering {
                        cachedKey = key
                        cachedFrame = frame
                        ready = true
                        onReady(true)
                        return
                    }
                }
                throw StillStereoRenderer.Failure.unavailable
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                clear()
                onReady(false)
                RAVEMediaLog.stills.error("Still stereo preparation failed")
            }
        }
    }

    fileprivate struct Frame: @unchecked Sendable { let sample: CMReadySampleBuffer<[CMTaggedDynamicBuffer]> }

    /// One bake at a time across windows: two simultaneous conversions mustn't
    /// multiply the source + eye + codec working set. No work on the main actor.
    private actor Worker {
        static let shared = Worker()
        func prepareStill(image: CGImage, depth: StillDepthMap,
                     adjustments: RAVEAIDepthPhotoView.Adjustments, strength: Float, separatesBoundaries: Bool, mirror: Bool) throws -> RAVEStereoPhotoView.Frame {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let engine = StillStereoRenderer() else { throw StillStereoRenderer.Failure.unavailable }
                let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
                let context = CIContext(options: [.workingColorSpace: cs, .cacheIntermediates: false])
                var input = CIImage(cgImage: image)
                let target = StillStereoResolution.longSide(width: image.width, height: image.height,
                    requested: Double(max(image.width, image.height)))
                if target < max(image.width, image.height) {
                    let scale = CGFloat(target) / CGFloat(max(image.width, image.height))
                    input = input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
                }
                if adjustments.autoEnhance {
                    for filter in input.autoAdjustmentFilters(options: [.enhance: true, .redEye: false]) {
                        filter.setValue(input, forKey: kCIInputImageKey)
                        if let output = filter.outputImage { input = output }
                    }
                }
                input = input.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: adjustments.brightness,
                    kCIInputContrastKey: 1 + (adjustments.contrast - 1) * 0.12,
                    kCIInputSaturationKey: adjustments.saturation])
                guard let source = context.createCGImage(input, from: input.extent, format: .RGBAh, colorSpace: cs) else {
                    throw StillStereoRenderer.Failure.allocation
                }
                let result = try engine.render(image: source, depth: depth, strength: strength, separatesBoundaries: separatesBoundaries, mirror: mirror)
                try Task.checkCancellation()
                let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
                func buffer(_ texture: MTLTexture) throws -> CVReadOnlyPixelBuffer {
                    var pixelBuffer: CVPixelBuffer?
                    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                        kCVPixelBufferMetalCompatibilityKey: true]
                    guard CVPixelBufferCreate(nil, texture.width & ~1, texture.height & ~1,
                        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attributes as CFDictionary,
                        &pixelBuffer) == kCVReturnSuccess, let pixelBuffer,
                        let ci = CIImage(mtlTexture: texture, options: [.colorSpace: result.colorSpace]) else {
                        throw StillStereoRenderer.Failure.allocation
                    }
                    // The warp uses top-left texture UVs; Core Image uses bottom-left.
                    let oriented = ci.transformed(by: CGAffineTransform(translationX: 0,
                        y: CGFloat(texture.height)).scaledBy(x: 1, y: -1))
                    CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                    CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
                    CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
                    context.render(oriented, to: pixelBuffer, bounds: CGRect(x: 0, y: 0,
                        width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)), colorSpace: pq)
                    return CVReadOnlyPixelBuffer(CVMutablePixelBuffer(unsafeBuffer: pixelBuffer))
                }
                let tagged: [CMTaggedDynamicBuffer] = [
                    CMTaggedDynamicBuffer(tags: [.videoLayerID(0), .stereoView(.leftEye), .mediaType(.video)],
                        content: .pixelBuffer(try buffer(result.left))),
                    CMTaggedDynamicBuffer(tags: [.videoLayerID(1), .stereoView(.rightEye), .mediaType(.video)],
                        content: .pixelBuffer(try buffer(result.right)))]
                let sample = CMReadySampleBuffer(taggedBuffers: tagged,
                    formatDescription: CMTaggedBufferGroupFormatDescription(taggedBuffers: tagged),
                    presentationTimeStamp: .zero, duration: .invalid)
                return RAVEStereoPhotoView.Frame(sample: sample)
            }
        }
    }
}
#endif
