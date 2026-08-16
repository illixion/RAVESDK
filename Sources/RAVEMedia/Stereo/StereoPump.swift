/*
 RAVEMedia - StereoPump.

 Owns all per-frame GPU work for windowed fake-3D: pull the newest decoded
 frame, get depth for *that exact frame*, warp it into left/right eye buffers,
 convert to the compositor's native 420f, tag, and enqueue.

 CRITICAL: everything here runs on a dedicated background queue with its own
 MTLCommandQueue — NEVER on the main thread. An earlier version pumped on the
 main actor and blocked it with waitUntilCompleted ~90x/s, which starved Core
 Animation commits (backboardd render-watchdog SIGKILL) and the main-queue
 AVPlayer prepare callbacks (mediaplaybackd async-prepare watchdog), taking
 down the whole compositor.

 Frames arrive through `PumpFrameSource`, not from an AVPlayer directly. That
 seam is the point of this file living in a package: `AVPlayerFrameSource`
 (below) pulls from an `AVPlayerItemVideoOutput` exactly as Spatial Stash
 always has, while a browser can push decoded frames in from a WKWebView with
 no AVPlayer anywhere in the picture.

 visionOS 26 APIs: CMReadySampleBuffer / CMTaggedDynamicBuffer / CVReadOnlyPixelBuffer.
 */

#if os(visionOS)

import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import os
import QuartzCore
import VideoToolbox

/// One decoded frame on its way to the warp.
public struct PumpFrame {
    public let pixelBuffer: CVPixelBuffer
    /// Presentation time on the *source's* own timeline — what a cached depth
    /// source matches its baked depth against, and what a realtime source uses
    /// to decide whether a held map may be reused. Not the renderer timeline.
    public let itemTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, itemTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.itemTime = itemTime
    }
}

/// Where `StereoPump` gets frames. Called only on the pump queue (including
/// `invalidate`, from the stop-drain block), at the pump's tick rate.
///
/// The two implementations differ in kind, which is why this is a protocol and
/// not a parameter: a pull source is asked for the frame matching *now* and
/// answers nil when nothing new has decoded, while a push source hands over
/// whatever its decoder most recently deposited. Both must return nil rather
/// than repeat a frame the pump has already seen — a tick that re-warps the
/// same frame costs a full GPU pass and enqueues a duplicate.
public protocol PumpFrameSource: AnyObject, Sendable {
    /// The newest not-yet-delivered frame, or nil if none is ready.
    /// - Parameter hostTime: the pump's `CACurrentMediaTime()` for this tick, so
    ///   a source driven by a host-synchronised clock (AVPlayer) can map it onto
    ///   its own timeline. Push sources ignore it.
    func nextFrame(hostTime: CFTimeInterval) -> PumpFrame?
    /// Release decode resources; the pump is shutting down.
    func invalidate()
}

/// Pulls from an `AVPlayerItemVideoOutput` — the original Spatial Stash path,
/// where AVPlayer stays the clock, the audio source and the transport, and only
/// pixels are diverted.
public final class AVPlayerFrameSource: PumpFrameSource, @unchecked Sendable {
    private let output: AVPlayerItemVideoOutput

    public init(output: AVPlayerItemVideoOutput) {
        self.output = output
    }

    public func nextFrame(hostTime: CFTimeInterval) -> PumpFrame? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return nil
        }
        return PumpFrame(pixelBuffer: buffer, itemTime: itemTime)
    }

    public func invalidate() {}
}

/// CPU mirror of the Metal `VideoStereoUniforms` struct (8 floats, 2 float2s at
/// offsets 32/40 matching Metal's float2 alignment, then 2 more floats).
struct VideoStereoUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var depthStrength: Float
    var convergence: Float
    var eyeSign: Float
    var mirror: Float
    var useDepth: Float
    var depthUVScale: SIMD2<Float>
    var depthUVOffset: SIMD2<Float>
    var depthValueScale: Float
    var depthValueBias: Float
}

// MARK: - StereoPump (off-main: decode -> warp -> enqueue)

/// Owns all per-frame GPU work on a dedicated background queue with its own
/// command queue. `@unchecked Sendable`: the AVFoundation / CoreVideo / Metal
/// objects it holds are documented thread-safe, config is lock-guarded, and all
/// mutable state is touched only on `queue`.
public final class StereoPump: @unchecked Sendable {
    public struct Config {
        public var brightness: Float = 0
        public var contrast: Float = 1
        public var saturation: Float = 1
        /// Matches Pseudo3DSettings' Subtle default — always overwritten by
        /// makePumpConfig, but a missed config path should fail conservative.
        public var depthStrength: Float = 0.008
        /// Matches Pseudo3DSettings' default. Also the conservative fallback if a
        /// config path is ever missed: at 1.0 nothing crosses the window frame.
        public var convergence: Float = 1.0
        public var mirror: Bool = false

        public init(
            brightness: Float = 0,
            contrast: Float = 1,
            saturation: Float = 1,
            depthStrength: Float = 0.008,
            convergence: Float = 1.0,
            mirror: Bool = false
        ) {
            self.brightness = brightness
            self.contrast = contrast
            self.saturation = saturation
            self.depthStrength = depthStrength
            self.convergence = convergence
            self.mirror = mirror
        }
    }

    private let videoRenderer: AVSampleBufferVideoRenderer
    private let frameSource: PumpFrameSource
    private let warp: RAVEStereoWarpResources
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let startHostTime: CFTimeInterval
    private let onVideoSizeKnown: @Sendable (CGSize) -> Void

    private let queue = DispatchQueue(label: "com.illixion.ravemedia.stereo-pump", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    /// Backgrounded: **visionOS refuses GPU submission from a background app**,
    /// so every command buffer a tick builds is aborted with
    /// `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`. An
    /// `AVPlayer`-driven pump never noticed, because backgrounding pauses the
    /// player and a paused player yields no new frames — but a pump fed by a
    /// source that keeps producing (a web page's `<video>`, which keeps decoding
    /// and playing audio) ticks straight through it: ~6,800 aborted command
    /// buffers in 20 seconds on device, plus depth inference for every one of
    /// them. Read and written under `lifecycleLock`; only ever set from the
    /// notification observers below.
    private var isBackgrounded = false
    private let lifecycleLock = NSLock()
    private var lifecycleObservers: [NSObjectProtocol] = []

    private var textureCache: CVMetalTextureCache?
    /// BGRA Metal render targets for the warp (intermediate, not handed to the
    /// compositor).
    private var bgraPool: CVPixelBufferPool?
    /// 420v buffers handed to the renderer — built exactly like the validated
    /// test pattern (merged with `recommendedPixelBufferAttributes`).
    private var outPool: CVMutablePixelBuffer.Pool?
    private var poolWidth = 0
    private var poolHeight = 0
    /// Per-eye depth attachments for the occlusion-correct mesh warp ([0]=left,
    /// [1]=right). Separate textures because both eyes render in one command
    /// buffer; sharing one depth attachment let the right eye (2nd pass) test
    /// against the left eye's geometry, warping it more than the left.
    /// Multisampled + memoryless when MSAA is on (tile memory only, no backing).
    private var eyeDepthTextures: [MTLTexture?] = [nil, nil]
    /// Per-eye multisampled color targets for the MSAA mesh pass, resolved into
    /// the eye buffer by the render pass. Memoryless — only the resolve output
    /// (the eye buffer itself) is ever stored.
    private var eyeMSAAColorTextures: [MTLTexture?] = [nil, nil]
    /// Converts the BGRA warp output into the compositor's native 420v format.
    private let transferSession: VTPixelTransferSession
    /// Per-frame depth: realtime inference or PTS-matched cached depth (nil →
    /// heuristic warp only, e.g. a restored window whose model vanished).
    private let depthSource: PumpDepthSource?
    private var lastReportedSize: CGSize?
    /// When the depth source last transitioned unavailable → available; drives
    /// the flat→3D strength ramp in flatten mode (cached seek gaps, startup).
    private var depthResumeTime: CFTimeInterval?

    private let configLock = NSLock()
    private var config = Config()

    private let signposter = RAVEMediaLog.signposter

    /// Tick rate: 60fps in both modes — the warp is only a few ms, so the pump
    /// follows the source up to 60. Cached mode looks depth up by PTS; realtime
    /// mode infers at ~30Hz and holds the map for the in-between frame (see
    /// RealtimeDepthSource), with a slow inference gating its own tick so the
    /// cadence self-throttles. Either way a tick only enqueues when a genuinely
    /// new decoded frame exists.
    private let frameInterval: Double
    /// Seconds to ramp depth strength back after a flat gap (avoids a 3D "pop").
    private let depthRampDuration: Double = 0.15
    /// Bounds in-flight eye buffers so a stalled compositor can never make the
    /// pool allocate IOSurfaces without limit.
    private let maxInFlightBuffers = 8

    /// - Parameter warp: shared pipelines and grids; `RAVEStereoWarpResources.shared`
    ///   unless a caller has reason to build its own.
    /// - Returns: nil when Metal can't give the pump its own command queue or
    ///   the pixel-transfer session can't be created — both mean "no fake-3D",
    ///   which callers already handle by falling back to flat playback.
    public init?(
        videoRenderer: AVSampleBufferVideoRenderer,
        frameSource: PumpFrameSource,
        warp: RAVEStereoWarpResources,
        startHostTime: CFTimeInterval,
        depthSource: PumpDepthSource?,
        frameInterval: Double,
        onVideoSizeKnown: @escaping @Sendable (CGSize) -> Void
    ) {
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        guard let commandQueue = warp.device.makeCommandQueue(), let session else { return nil }
        self.videoRenderer = videoRenderer
        self.frameSource = frameSource
        self.warp = warp
        self.device = warp.device
        self.commandQueue = commandQueue
        self.startHostTime = startHostTime
        self.depthSource = depthSource
        self.frameInterval = frameInterval
        self.onVideoSizeKnown = onVideoSizeKnown
        self.transferSession = session
        CVMetalTextureCacheCreate(nil, nil, warp.device, nil, &textureCache)
    }

    public func updateConfig(_ newConfig: Config) {
        configLock.lock()
        config = newConfig
        configLock.unlock()
    }

    private func currentConfig() -> Config {
        configLock.lock(); defer { configLock.unlock() }
        return config
    }

    public func start() {
        observeAppLifecycle()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: frameInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers = []
        timer?.cancel()
        timer = nil
        // Drain on the pump queue so no tick races teardown.
        queue.async { [weak self] in
            guard let self else { return }
            depthSource?.invalidate()
            frameSource.invalidate()
            if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
            self.bgraPool = nil
            self.outPool = nil
            self.eyeDepthTextures = [nil, nil]
            self.eyeMSAAColorTextures = [nil, nil]
        }
    }

    /// The timer keeps running while backgrounded rather than being cancelled:
    /// the flag is one lock away on a path that already takes locks, and
    /// tearing the timer down and back up would have to be ordered against
    /// `stop()` racing a notification. Ticks become a lock and a return.
    private func observeAppLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let setBackgrounded: @Sendable (Bool) -> Void = { [weak self] backgrounded in
            guard let self else { return }
            lifecycleLock.lock()
            isBackgrounded = backgrounded
            lifecycleLock.unlock()
        }
        lifecycleObservers = [
            center.addObserver(
                forName: RAVEAppLifecycle.didEnterBackground, object: nil, queue: nil
            ) { _ in setBackgrounded(true) },
            center.addObserver(
                forName: RAVEAppLifecycle.willEnterForeground, object: nil, queue: nil
            ) { _ in setBackgrounded(false) }
        ]
    }

    // MARK: Per-frame work (always on `queue`)

    private func tick() {
        lifecycleLock.lock()
        let backgrounded = isBackgrounded
        lifecycleLock.unlock()
        // No GPU work at all while backgrounded — not the warp, and not the
        // depth inference that feeds it. The frame source keeps taking frames
        // and discarding all but the newest, so foregrounding resumes on
        // current content rather than replaying a backlog.
        guard !backgrounded else { return }

        guard videoRenderer.isReadyForMoreMediaData, let textureCache else { return }

        let hostTime = CACurrentMediaTime()
        guard let frame = frameSource.nextFrame(hostTime: hostTime) else { return }
        reportSizeIfNeeded(frame.pixelBuffer)

        // Tag relative to the synchronizer's zero-based, host-driven timeline so
        // the frame presents immediately and in order. Deliberately the host
        // clock, not the frame's own itemTime: the renderer's synchronizer
        // free-runs at rate 1 and only ever needs frames in order — the source's
        // timeline governs audio and seeking, and stays with the source.
        let pts = CMTime(seconds: hostTime - startHostTime, preferredTimescale: 90_000)
        renderAndEnqueue(from: frame.pixelBuffer, itemTime: frame.itemTime, cache: textureCache, pts: pts)
    }

    /// Warp the mono frame into two BGRA eye render targets, convert each to a
    /// 420v buffer (the compositor's native format) via VTPixelTransferSession,
    /// then tag and enqueue. The 420v buffers come from a pool merged with
    /// `recommendedPixelBufferAttributes` — the construction validated on-device.
    /// `CVMutablePixelBuffer` is noncopyable, so the two eye buffers stay local:
    /// borrowed by `transfer`, then consumed by `CVReadOnlyPixelBuffer`.
    private func renderAndEnqueue(from src: CVPixelBuffer, itemTime: CMTime, cache: CVMetalTextureCache, pts: CMTime) {
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        guard width > 0, height > 0,
              ensurePools(width: width, height: height),
              let bgraPool, let outPool,
              let srcTexture = makeTexture(from: src, cache: cache) else { return }

        // 1. Warp into two BGRA eye render targets.
        var leftBGRA: CVPixelBuffer?
        var rightBGRA: CVPixelBuffer?
        let aux: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: maxInFlightBuffers]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, bgraPool, aux as CFDictionary, &leftBGRA) == kCVReturnSuccess,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, bgraPool, aux as CFDictionary, &rightBGRA) == kCVReturnSuccess,
              let leftBGRA, let rightBGRA,
              let leftTex = makeTexture(from: leftBGRA, cache: cache),
              let rightTex = makeTexture(from: rightBGRA, cache: cache),
              let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // Depth matched to THIS exact frame: realtime inference blocks until the
        // frame's own depth is ready (slow inference just yields fewer frames);
        // cached mode looks the frame's depth up by presentation time. Either
        // way, image and depth can never mismatch — no ghosting.
        let depthState = signposter.beginInterval("pump-depth")
        let frameDepth = depthSource?.frameDepth(itemTime: itemTime, frame: src)
        signposter.endInterval("pump-depth", depthState)

        var cfg = currentConfig()
        if depthSource?.flattensWhenUnavailable == true {
            // Cached mode: a seek/startup gap renders FLAT (never the heuristic
            // warp, never stale depth), then depth ramps back in to avoid a pop.
            if frameDepth == nil {
                depthResumeTime = nil
                cfg.depthStrength = 0
            } else {
                let now = CACurrentMediaTime()
                let since = depthResumeTime ?? { depthResumeTime = now; return now }()
                cfg.depthStrength *= Float(min(1, (now - since) / depthRampDuration))
            }
        }

        let warpState = signposter.beginInterval("pump-warp")
        encodeEye(into: leftTex, source: srcTexture, depth: frameDepth, eyeSign: 1.0, config: cfg, commandBuffer: cmdBuf)
        encodeEye(into: rightTex, source: srcTexture, depth: frameDepth, eyeSign: -1.0, config: cfg, commandBuffer: cmdBuf)
        cmdBuf.commit()
        // Safe here: this runs on the background pump queue, never main. The warp
        // must complete before VTPixelTransferSession reads the BGRA surfaces.
        cmdBuf.waitUntilCompleted()
        signposter.endInterval("pump-warp", warpState)

        // 2. Convert each BGRA eye → 420v from the recommended-attributes pool,
        // carrying the source's color tags so the compositor reads gamma/range
        // correctly (untagged YCbCr was being misinterpreted = washed out).
        let transferState = signposter.beginInterval("pump-transfer")
        defer { signposter.endInterval("pump-transfer", transferState) }
        guard let left = try? outPool.makeMutablePixelBuffer() else { return }
        guard transfer(from: leftBGRA, to: left) else { return }
        tagColor(left, from: src)
        guard let right = try? outPool.makeMutablePixelBuffer() else { return }
        guard transfer(from: rightBGRA, to: right) else { return }
        tagColor(right, from: src)

        // 3. Tag, describe, enqueue. CVReadOnlyPixelBuffer(_:) consumes each
        // mutable buffer (move), and the format description is built from the
        // tagged group — both exactly as Apple's sample does. (Omitting the
        // format description / using BGRA was a cause of the earlier GPU hang.)
        let presentation = pts.isValid ? pts : .zero
        let leftTags: [CMTag] = [.videoLayerID(0), .stereoView(.leftEye), .mediaType(.video)]
        let rightTags: [CMTag] = [.videoLayerID(1), .stereoView(.rightEye), .mediaType(.video)]
        let tagged: [CMTaggedDynamicBuffer] = [
            CMTaggedDynamicBuffer(tags: leftTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(left))),
            CMTaggedDynamicBuffer(tags: rightTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(right)))
        ]
        let sample = CMReadySampleBuffer(
            taggedBuffers: tagged,
            formatDescription: CMTaggedBufferGroupFormatDescription(taggedBuffers: tagged),
            presentationTimeStamp: presentation,
            duration: CMTime(value: 1, timescale: 90)
        )
        sample.withUnsafeSampleBuffer { videoRenderer.enqueue($0) }
    }

    private func transfer(from source: CVPixelBuffer, to dest: borrowing CVMutablePixelBuffer) -> Bool {
        var ok = false
        dest.withUnsafeBuffer { destBuffer in
            ok = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destBuffer) == noErr
        }
        return ok
    }

    /// Copy the source frame's color primaries / transfer function / YCbCr matrix
    /// onto the eye buffer (defaulting to Rec.709). Without these the compositor
    /// guesses the color space and renders the eyes washed out.
    private func tagColor(_ dest: borrowing CVMutablePixelBuffer, from src: CVPixelBuffer) {
        dest.withUnsafeBuffer { d in
            let primaries = CVBufferGetAttachment(src, kCVImageBufferColorPrimariesKey, nil)?.takeUnretainedValue()
                ?? kCVImageBufferColorPrimaries_ITU_R_709_2
            CVBufferSetAttachment(d, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)

            let transfer = CVBufferGetAttachment(src, kCVImageBufferTransferFunctionKey, nil)?.takeUnretainedValue()
                ?? kCVImageBufferTransferFunction_ITU_R_709_2
            CVBufferSetAttachment(d, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)

            let matrix = CVBufferGetAttachment(src, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue()
                ?? kCVImageBufferYCbCrMatrix_ITU_R_709_2
            CVBufferSetAttachment(d, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
    }

    private func encodeEye(
        into dest: MTLTexture,
        source: MTLTexture,
        depth: PumpFrameDepth?,
        eyeSign: Float,
        config: Config,
        commandBuffer: MTLCommandBuffer
    ) {
        var uniforms = VideoStereoUniforms(
            brightness: config.brightness,
            contrast: config.contrast,
            saturation: config.saturation,
            depthStrength: config.depthStrength,
            convergence: config.convergence,
            eyeSign: eyeSign,
            mirror: config.mirror ? 1.0 : 0.0,
            useDepth: depth != nil ? 1.0 : 0.0,
            depthUVScale: depth?.uvScale ?? SIMD2(1, 1),
            depthUVOffset: depth?.uvOffset ?? SIMD2(0, 0),
            depthValueScale: depth?.valueScale ?? 1,
            depthValueBias: depth?.valueBias ?? 0
        )

        // With a real depth map: occlusion-correct depth-displaced mesh. Without
        // one: the per-pixel heuristic warp. Each eye gets its own depth
        // attachment (0=left, 1=right) — the two eyes render in one command
        // buffer, so a shared attachment cross-contaminated the depth test.
        let eyeIndex = eyeSign > 0 ? 0 : 1
        if let depth, let depthAttachment = ensureDepthTexture(width: dest.width, height: dest.height, eye: eyeIndex) {
            let desc = MTLRenderPassDescriptor()
            // MSAA: rasterize into a memoryless multisampled target and resolve
            // into the eye buffer — the mesh's occlusion boundaries are raster
            // edges with no texture-side AA and stairstep without it. The
            // pipeline is built at pseudo3DMSAASampleCount, so the attachments
            // must match; if the transient MSAA target can't be made (never
            // observed — memoryless has no memory backing), skip the frame.
            if warp.msaaSampleCount > 1 {
                guard let msaaColor = ensureMSAAColorTexture(width: dest.width, height: dest.height, eye: eyeIndex) else { return }
                desc.colorAttachments[0].texture = msaaColor
                desc.colorAttachments[0].resolveTexture = dest
                desc.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                desc.colorAttachments[0].texture = dest
                desc.colorAttachments[0].storeAction = .store
            }
            desc.colorAttachments[0].loadAction = .clear
            desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            desc.depthAttachment.texture = depthAttachment
            desc.depthAttachment.loadAction = .clear
            desc.depthAttachment.clearDepth = 1.0
            desc.depthAttachment.storeAction = .dontCare
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return }
            // Grid density per depth source: dense for cached (edge-aware) depth,
            // moderate for realtime — see PumpDepthSource.prefersDenseWarpGrid.
            let dense = depthSource?.prefersDenseWarpGrid == true
            encoder.setRenderPipelineState(warp.meshPipelineState)
            encoder.setDepthStencilState(warp.meshDepthState)
            encoder.setVertexBuffer(dense ? warp.denseGridPositions : warp.gridPositions, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoStereoUniforms>.size, index: 1)
            encoder.setVertexTexture(depth.texture, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoStereoUniforms>.size, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: dense ? warp.denseGridIndexCount : warp.gridIndexCount,
                indexType: .uint32, indexBuffer: dense ? warp.denseGridIndices : warp.gridIndices, indexBufferOffset: 0
            )
            encoder.endEncoding()
            return
        }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = dest
        desc.colorAttachments[0].loadAction = .dontCare
        desc.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return }
        encoder.setRenderPipelineState(warp.eyePipelineState)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(source, index: 1) // placeholder; unused when useDepth=0
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoStereoUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private func ensureDepthTexture(width: Int, height: Int, eye: Int) -> MTLTexture? {
        if let existing = eyeDepthTextures[eye], existing.width == width, existing.height == height {
            return existing
        }
        let texture = device.makeTexture(descriptor: transientAttachmentDescriptor(
            pixelFormat: .depth32Float, width: width, height: height
        ))
        eyeDepthTextures[eye] = texture
        return texture
    }

    /// Multisampled color target for the MSAA mesh pass (resolved into the eye
    /// buffer). Only called when pseudo3DMSAASampleCount > 1.
    private func ensureMSAAColorTexture(width: Int, height: Int, eye: Int) -> MTLTexture? {
        if let existing = eyeMSAAColorTextures[eye], existing.width == width, existing.height == height {
            return existing
        }
        let texture = device.makeTexture(descriptor: transientAttachmentDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height
        ))
        eyeMSAAColorTextures[eye] = texture
        return texture
    }

    /// Descriptor for a load-clear/store-discard render attachment: multisampled
    /// at the mesh pipeline's sample count and memoryless (tile memory only —
    /// contents never survive the pass, which is all the mesh pass needs from
    /// its depth buffer and its pre-resolve color).
    private func transientAttachmentDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int) -> MTLTextureDescriptor {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        desc.usage = [.renderTarget]
        let samples = warp.msaaSampleCount
        if samples > 1 {
            desc.textureType = .type2DMultisample
            desc.sampleCount = samples
            desc.storageMode = .memoryless
        } else {
            desc.storageMode = .private
        }
        return desc
    }

    // MARK: GPU helpers

    /// (Re)creates the BGRA warp pool and the 420v output pool for the current
    /// source dimensions. Returns false if either pool can't be made.
    private func ensurePools(width: Int, height: Int) -> Bool {
        if bgraPool != nil, outPool != nil, poolWidth == width, poolHeight == height { return true }

        let bgraAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var bgra: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, bgraAttrs as CFDictionary, &bgra) == kCVReturnSuccess else { return false }

        // 420 output pool, merged with the renderer's recommended attributes —
        // the construction that validated on-device. Full-range (420f, luma
        // 0-255) rather than video-range (420v, 16-235): our warp output is
        // full-range RGB and the compositor reads the tagged buffer as full
        // range, so video-range here lifts blacks / lowers whites (washed out).
        let eyeSize = CVImageSize(width: width, height: height)
        let defaultAttributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            size: eyeSize
        )
        let recommended = videoRenderer.recommendedPixelBufferAttributes
        guard let merged = CVPixelBufferAttributes(merging: [CVPixelBufferAttributes(defaultAttributes), recommended]),
              let creation = CVPixelBufferCreationAttributes(merged),
              let out = try? CVMutablePixelBuffer.Pool(pixelBufferAttributes: creation) else { return false }

        bgraPool = bgra
        outPool = out
        poolWidth = width
        poolHeight = height
        return true
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        ) == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func reportSizeIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard size.width > 0, size.height > 0, lastReportedSize != size else { return }
        lastReportedSize = size
        onVideoSizeKnown(size)
    }
}

#endif
