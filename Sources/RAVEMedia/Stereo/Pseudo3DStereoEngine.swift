/*
 RAVEMedia - Pseudo3DStereoEngine.

 Real-time "fake 3D" video in an ordinary Shared-Space window — no immersive
 space, no MV-HEVC pre-compute. Architecture:

   AVPlayer (audio + master clock + transport + scrubbing + A-B loop)
        |  decoded mono frames via AVPlayerItemVideoOutput
        v
   StereoPump (dedicated background queue): warp the mono frame into LEFT +
        |  RIGHT eye buffers using Core ML depth
        v
   tagged CMReadySampleBuffer (.leftEye / .rightEye)
        v
   AVSampleBufferVideoRenderer -> VideoPlayerComponent(.stereo) in a RealityView

 The renderer's synchronizer free-runs at rate 1; each warped frame is tagged
 with a host-clock timestamp relative to that start, so AVPlayer stays the only
 clock governing audio/pause/seek and the sample-buffer renderer is purely a
 stereoscopic presentation surface. The eye pool is bounded (allocation
 threshold) and the pump is rate-capped so it can never flood the compositor.

 **What is deliberately not here.** The SwiftUI view stays in the app: it is
 where window-chrome constants, gesture wiring and per-app models live, and
 none of that generalises. So does the binding of transport commands to an
 app's own playback model — this exposes `play`/`pause`/`seek`/`setMuted` and
 publishes `RAVEPlaybackState`, and the app decides what to wire them to.

 visionOS 26 APIs: CMReadySampleBuffer / CMTaggedDynamicBuffer / CVReadOnlyPixelBuffer.
 */

#if os(visionOS)

import AVFoundation
import CoreMedia
import Foundation
import Observation
import os
import QuartzCore
import RealityKit
import SwiftUI

/// Diagnostics for the windowed-stereo pipeline. While `useStaticTestPattern`
/// is true, the engine bypasses AVPlayer and the Metal warp entirely and feeds
/// the renderer a static stereo test pattern built exactly like Apple's
/// "Rendering stereoscopic video with RealityKit" sample (420v buffers from a
/// pool merged with `recommendedPixelBufferAttributes`, proper format
/// description, pull-model enqueue). This isolates whether the windowed-stereo
/// plumbing itself is stable on-device before re-introducing our own decode/warp.
public enum Pseudo3DDiagnostics {
    public static let useStaticTestPattern = false
}

/// What the engine publishes about playback, for an app to mirror into whatever
/// model drives its transport UI.
///
/// A struct rather than the app type it replaced: the engine has no business
/// knowing about a particular app's window model, and two apps that both want
/// a scrubber want the same five numbers.
public struct RAVEPlaybackState: Equatable, Sendable {
    public let currentTime: Double
    public let duration: Double
    public let paused: Bool
    public let muted: Bool
    /// Furthest buffered position, in seconds.
    public let buffered: Double

    public init(currentTime: Double, duration: Double, paused: Bool, muted: Bool, buffered: Double) {
        self.currentTime = currentTime
        self.duration = duration
        self.paused = paused
        self.muted = muted
        self.buffered = buffered
    }
}

/// Colour adjustments folded into the warp shader, so the stereo path keeps the
/// same look as the flat player. Only the three the shader consumes — an app's
/// wider adjustment model (opacity, sharpen, auto-enhance) is applied elsewhere
/// and has no meaning here.
public struct RAVEColorAdjustments: Equatable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
    }

    public static let neutral = RAVEColorAdjustments()
}

// MARK: - Engine (main-actor: SwiftUI + transport only)

@MainActor
@Observable
public final class Pseudo3DStereoEngine {
    // Presentation
    public let videoRenderer = AVSampleBufferVideoRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var didStartSynchronizer = false

    // Source / clock
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var loadedURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var isRoomActive = true
    /// Playback state captured at room exit; room re-entry restores it so a
    /// manual pause survives focus/room flaps.
    private var wasPlayingBeforeRoomExit = true

    // Off-main frame pump (owns all per-frame GPU work).
    private var pump: StereoPump?
    // Diagnostic static-pattern pump (used when Pseudo3DDiagnostics.useStaticTestPattern).
    private var testPump: StereoTestPatternPump?

    // RealityView video entity + fit-to-window state. VideoPlayerComponent's
    // screen defaults to ~2× our window (Apple's sample scales it to fit), so we
    // scale the entity to the RealityView's bounds.
    @ObservationIgnored public private(set) var videoEntity: Entity?
    @ObservationIgnored private var lastViewBounds: BoundingBox?
    @ObservationIgnored private var sizeSubscription: EventSubscription?
    @ObservationIgnored private var refitBurstTask: Task<Void, Never>?
    /// Decoded video dimensions from the pump's first frame — drives the
    /// content-aware fit (the component's screen mesh doesn't reflect them).
    @ObservationIgnored private var knownVideoSize: CGSize?
    @ObservationIgnored private var tapTargetInstalled = false
    /// While true, fade the video so an open menu/popover shows through it.
    @ObservationIgnored private var chromeOpen = false
    /// Video opacity while a menu/popover is open (low = chrome clearly visible).
    @ObservationIgnored private let chromeDimOpacity: Float = 0.12
    /// Caller-driven opacity (slideshow crossfades), multiplied with the chrome
    /// dim. SwiftUI's `.opacity` doesn't reach RealityKit content on visionOS.
    @ObservationIgnored private var contentOpacity: Float = 1

    // Config
    private var adjustments = RAVEColorAdjustments.neutral
    private var settings = Pseudo3DSettings.default
    private var isFlipped = false
    /// Where depth comes from: realtime inference (~30Hz, held for in-between
    /// frames at 60fps video) or a pre-processed cache entry (exact PTS sync).
    /// Changing it reloads the pump.
    private var depthMode: Pseudo3DDepthMode = .realtime
    /// Physical width of the fitted video plane in meters (videoAspect × entity
    /// scale, tracked by fitVideo). Drives plane-size disparity normalization —
    /// see makePumpConfig.
    @ObservationIgnored private var planeWidthMeters: Float?

    // A-B loop
    private var loopA: Double?
    private var loopB: Double?

    /// Initial mute state applied to a freshly loaded player.
    @ObservationIgnored public var startMuted = true
    /// Restart at the top when playback reaches the end.
    @ObservationIgnored public var loops = true

    // Callbacks
    @ObservationIgnored public var onVideoSizeKnown: ((CGSize) -> Void)?
    @ObservationIgnored public var onPlaybackError: (() -> Void)?
    @ObservationIgnored public var onDurationKnown: ((Double) -> Void)?
    /// One-shot latch for `onDurationKnown` (duration is polled from the
    /// periodic time observer, which fires ~30×/s). Reset per loaded item.
    @ObservationIgnored private var didReportDuration = false
    /// Publishes transport state on every periodic time observation. The app
    /// binds this to whatever model drives its scrubber; the engine has no
    /// opinion about what that model is.
    @ObservationIgnored public var onPlaybackUpdate: ((RAVEPlaybackState) -> Void)?

    public init() {
        synchronizer.addRenderer(videoRenderer)
    }

    // MARK: Entity

    public func makeVideoEntity() -> Entity {
        let entity = Entity()
        var component = VideoPlayerComponent(videoRenderer: videoRenderer)
        component.desiredViewingMode = VideoPlaybackController.ViewingMode.stereo
        component.isPassthroughTintingEnabled = false
        entity.components.set(component)
        videoEntity = entity
        // Sync the fade state now the entity exists — setChromeOpen may have
        // fired (with the initial chromeOpen) before this, when videoEntity was
        // still nil. Applied here (once, at creation) rather than in refitVideo,
        // which runs on every layout/ornament change and wrongly re-tied the
        // opacity to ornament visibility.
        applyChromeOpacity()
        return entity
    }

    /// Subscribe to the video screen-size event so we re-fit once the plane has
    /// real dimensions (its visualBounds is empty until then). Call from the
    /// RealityView make closure where `content` is available.
    public func observeVideoSize(content: RealityViewContent) {
        guard let entity = videoEntity else { return }
        sizeSubscription = content.subscribe(
            to: VideoPlayerEvents.VideoSizeDidChange.self, on: entity
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refitVideo() }
        }
    }

    /// Store the latest RealityView bounds (scene space) and fit to them.
    public func updateViewBounds(_ bounds: BoundingBox) {
        lastViewBounds = bounds
        refitVideo()
    }

    private func refitVideo() {
        guard let bounds = lastViewBounds else { return }
        fitVideo(toViewBounds: bounds)
        installTapTarget()
    }

    /// Re-fit once the real video size is known (from the pump's first decoded
    /// frame) — fitVideo then scales from the video aspect, so the first pass
    /// fixes the size. The loop afterwards waits for the screen mesh to settle
    /// at its aspect-correct dims (it reads 1×1 until frames present, with no
    /// event on the change) and then rebuilds the tap target, which would
    /// otherwise keep the placeholder square's bounds; on timeout it rebuilds
    /// anyway (a square target is a harmless superset).
    private func scheduleRefitBurst() {
        refitBurstTask?.cancel()
        refitBurstTask = Task { [weak self] in
            guard let self else { return }
            let aspect = self.knownVideoSize.map { Float($0.width / max($0.height, 1)) }
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                self.refitVideo()
                if let entity = self.videoEntity, let aspect {
                    let ext = entity.visualBounds(relativeTo: entity).extents
                    if ext.x > 1e-4, ext.y > 1e-4, abs(ext.x / ext.y - aspect) < aspect * 0.02 {
                        break // mesh adopted the video dims
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            self.tapTargetInstalled = false
            self.installTapTarget()
        }
    }

    /// Give the video entity a collision shape + input target so a SpatialTapGesture
    /// can land on it (a 2D overlay can't catch gaze over a RealityView). Sized to
    /// the video plane in local space so the entity's fit-scale maps it correctly.
    private func installTapTarget() {
        guard let entity = videoEntity, !tapTargetInstalled else { return }
        let local = entity.visualBounds(relativeTo: entity)
        guard local.extents.x > 0.001, local.extents.y > 0.001 else { return }
        let box = ShapeResource.generateBox(
            width: local.extents.x, height: local.extents.y, depth: max(local.extents.z, 0.05)
        ).offsetBy(translation: local.center)
        entity.components.set(CollisionComponent(shapes: [box], isStatic: true))
        entity.components.set(InputTargetComponent())
        tapTargetInstalled = true
    }

    /// Scale the video entity so its plane fits within `bounds` (preserving
    /// aspect). Converges in one or two calls because it sets an absolute scale
    /// derived from the entity's unscaled size.
    private func fitVideo(toViewBounds bounds: BoundingBox) {
        guard let entity = videoEntity else { return }

        // Center the entity on the window plane. (Depth can't be used to dodge
        // an open menu — the zero-depth slab clips any off-plane entity, and a
        // SwiftUI .offset(z:) perturbs this fit; menu occlusion is handled by
        // fading the entity via OpacityComponent instead — see setChromeOpen.)
        entity.position = bounds.center

        let extents = entity.visualBounds(relativeTo: nil).extents
        let scale = entity.scale.x
        guard extents.x > 1e-4, extents.y > 1e-4, scale > 1e-4,
              bounds.extents.x > 1e-4, bounds.extents.y > 1e-4 else { return }
        let unscaledX = extents.x / scale
        let unscaledY = extents.y / scale
        // The component's screen mesh reads 1×1 until the first frames
        // present, then settles at (videoAspect × 1)m — with no fit trigger:
        // VideoSizeDidChange doesn't fire for renderer-backed components, so
        // any scale derived from *measured* mesh bounds is computed against
        // the stale square (observed on visionOS 26: tall videos ended up
        // undersized, wide ones cropped by ~the aspect ratio, depending on
        // which formula met the square). Derive the screen dims from the
        // pump-reported video aspect instead — (a, 1) in mesh-local meters —
        // and only fall back to measured bounds before the size is known.
        let target: Float
        if let size = knownVideoSize, size.width > 0, size.height > 0 {
            let videoAspect = Float(size.width / size.height)
            target = min(bounds.extents.x / videoAspect, bounds.extents.y)
        } else {
            target = min(bounds.extents.x / unscaledX, bounds.extents.y / unscaledY)
        }
        // Track the plane's physical width (the mesh is videoAspect × 1 m
        // pre-scale) and re-normalize disparity when it changes meaningfully.
        // Before the |target − scale| guard: the width must be known even when
        // the scale itself doesn't need re-applying.
        if let size = knownVideoSize, size.width > 0, size.height > 0,
           target.isFinite, target > 1e-4 {
            let width = Float(size.width / size.height) * target
            if abs((planeWidthMeters ?? 0) - width) > 0.01 {
                planeWidthMeters = width
                pump?.updateConfig(makePumpConfig())
            }
        }
        guard target.isFinite, target > 1e-4, abs(target - scale) > 0.02 else { return }
        RAVEMediaLog.pipeline.info("fitVideo: bounds \(bounds.extents.x)x\(bounds.extents.y), mesh \(unscaledX)x\(unscaledY), videoAspect \(self.knownVideoSize.map { Float($0.width / $0.height) } ?? -1), scale \(scale) → \(target)")
        entity.scale = SIMD3<Float>(repeating: target)
    }

    // MARK: Config

    public func configure(adjustments: RAVEColorAdjustments, settings: Pseudo3DSettings, isFlipped: Bool) {
        self.adjustments = adjustments
        self.settings = settings
        self.isFlipped = isFlipped
        pump?.updateConfig(makePumpConfig())
    }

    /// Fade/restore the video when a menu/popover opens/closes, so the presented
    /// chrome shows through the (front-plane) video instead of being occluded.
    public func setChromeOpen(_ open: Bool) {
        chromeOpen = open
        applyChromeOpacity()
    }

    /// Caller-driven plane opacity (slideshow crossfade). Composes with the
    /// chrome dim rather than replacing it.
    public func setContentOpacity(_ opacity: Double) {
        let clamped = Float(max(0, min(1, opacity)))
        guard abs(contentOpacity - clamped) > 0.001 else { return }
        contentOpacity = clamped
        applyChromeOpacity()
    }

    /// Reflect `chromeOpen` on the entity. Called from setChromeOpen AND after
    /// the entity is (re)fit, so the state is consistent even when the entity is
    /// created after the first setChromeOpen (which otherwise left it desynced —
    /// the first menu wouldn't fade, later ones would).
    private func applyChromeOpacity() {
        let opacity = contentOpacity * (chromeOpen ? chromeDimOpacity : 1.0)
        videoEntity?.components.set(OpacityComponent(opacity: opacity))
    }

    /// Plane width (meters) above which `depthStrength` is attenuated. The warp
    /// bakes disparity as a fraction of frame width, so the physical separation
    /// it demands of the eyes grows with the window — a Medium that fuses fine
    /// on a small window exceeds the ~1° vergence comfort zone on a large one.
    /// Attenuation-ONLY (min(1, ref/width)): a preset means at most its UV value,
    /// capped to a constant physical disparity once the plane exceeds the
    /// reference. Never amplify on small windows — an earlier symmetric version
    /// scaled small-window strength up into the 0.04 ceiling, which collapsed
    /// Medium and Strong into the same (excessive) disparity and re-amplified
    /// silhouette stairstepping.
    private static let referencePlaneWidthMeters: Float = 1.0

    private func makePumpConfig() -> StereoPump.Config {
        // Fixed at the (Subtle) default — persisted settings may carry a legacy
        // user-tuned strength, which is deliberately ignored (values above the
        // default don't fuse comfortably; see Pseudo3DSettings.depthStrength).
        var strength = Float(Pseudo3DSettings.default.depthStrength)
        if let planeWidth = planeWidthMeters, planeWidth > 0.05 {
            strength *= min(1, Self.referencePlaneWidthMeters / planeWidth)
        }
        return StereoPump.Config(
            brightness: Float(adjustments.brightness),
            contrast: Float(adjustments.contrast),
            saturation: Float(adjustments.saturation),
            depthStrength: strength,
            convergence: Float(settings.convergence),
            mirror: isFlipped
        )
    }

    // MARK: Load / transport

    public var currentTime: Double { player?.currentTime().seconds ?? 0 }

    /// Switch depth mode; reloads the current video when it actually changes
    /// (the pump's depth source and tick rate are fixed at load time).
    public func setDepthMode(_ mode: Pseudo3DDepthMode) {
        guard depthMode != mode else { return }
        depthMode = mode
        reloadDepthPipeline()
    }

    /// Rebuild the pump — and with it the depth provider / cache reader — for
    /// the currently loaded video, preserving position and pause state. Used
    /// when the preferred depth model changes so a switch applies to the video
    /// being watched, not just the next one opened.
    public func reloadDepthPipeline() {
        guard let url = loadedURL else { return }
        let resumeTime = currentTime
        let wasPaused = player?.timeControlStatus == .paused
        let wasMuted = player?.isMuted ?? startMuted
        let savedLoopA = loopA
        let savedLoopB = loopB
        loadedURL = nil
        load(url: url, roomActive: isRoomActive)
        setLoopBounds(a: savedLoopA, b: savedLoopB)
        if resumeTime > 0 { seek(to: resumeTime) }
        if wasPaused { pause() }
        setMuted(wasMuted)
    }

    public func load(url: URL, roomActive: Bool, depthMode requestedMode: Pseudo3DDepthMode? = nil, startAt: Double? = nil, startPaused: Bool = false) {
        if let requestedMode { depthMode = requestedMode }
        guard loadedURL != url else { return }

        // Cached mode plays back baked depth and needs no model; resolve its
        // entry up front (a missing/deleted cache falls back to realtime). A
        // still-converting entry is accepted too — progressive playback; the
        // reader follows the growing file.
        var cacheEntry: DepthCacheStore.Entry?
        if case .cached(let videoIdentity) = depthMode {
            cacheEntry = DepthCacheStore.entry(videoIdentity: videoIdentity)
            // A running conversion supersedes an older completed entry (e.g.
            // re-converting with a newly selected pre-process model): follow
            // the growing file so playback shows the depth just asked for.
            if DepthConversionManager.shared.isProcessing(videoIdentity: videoIdentity),
               let growing = DepthCacheStore.inProgressEntry(videoIdentity: videoIdentity) {
                cacheEntry = growing
            }
            if cacheEntry == nil {
                RAVEMediaLog.pipeline.warning("Depth cache entry missing for \(videoIdentity, privacy: .private); falling back to realtime")
            }
        }

        // Fake-3D requires real depth — there is no heuristic fallback. Without
        // a cache entry or a model (e.g. a restored window whose model was since
        // deleted), fall back to the flat player rather than warping heuristically.
        guard Pseudo3DDiagnostics.useStaticTestPattern || cacheEntry != nil || CoreMLDepthProvider.hasAvailableModel(role: .realtime) else {
            Task { @MainActor in self.onPlaybackError?() }
            return
        }

        cleanupPlayer()
        loadedURL = url
        isRoomActive = roomActive
        knownVideoSize = nil
        refitBurstTask?.cancel()

        // Diagnostic: prove the windowed-stereo plumbing in isolation, no
        // AVPlayer / decode / warp. See Pseudo3DDiagnostics.
        if Pseudo3DDiagnostics.useStaticTestPattern {
            if !didStartSynchronizer {
                didStartSynchronizer = true
                synchronizer.setRate(1, time: .zero)
            }
            onVideoSizeKnown?(CGSize(width: 1280, height: 720))
            let pump = StereoTestPatternPump(videoRenderer: videoRenderer)
            pump.start()
            testPump = pump
            return
        }

        // No Metal / no shader library means no warp at all — report the same
        // failure the caller already handles by dropping to the flat player,
        // rather than opening a player whose frames can never be presented.
        guard let warp = RAVEStereoWarpResources.shared else {
            Task { @MainActor in self.onPlaybackError?() }
            return
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.applySpatialAudioPolicy()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.applySpatialAudioPolicy(for: asset)
        player.isMuted = startMuted
        player.automaticallyWaitsToMinimizeStalling = true

        self.player = player
        self.playerItem = item
        self.videoOutput = output

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Non-looping (slideshow clip longer than the dwell interval):
                // park on the last frame and let the caller time the advance.
                guard self.loops else {
                    self.reportPlaybackState()
                    return
                }
                self.seek(to: 0)
                if self.isRoomActive { self.play() }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onPlaybackError?() }
        }
        // Load failures (bad URL/auth/TLS/container) set item.status = .failed
        // without ever firing FailedToPlayToEndTime — observe it so the caller's
        // fallback (flat player / 2D) engages instead of a silent black plane.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            let message = observedItem.error?.localizedDescription ?? "unknown error"
            Task { @MainActor [weak self] in
                guard let self, self.playerItem === observedItem else { return }
                RAVEMediaLog.pipeline.error("Pseudo-3D player item failed for \(self.loadedURL?.redactedForLogging ?? "?", privacy: .public): \(message, privacy: .public)")
                self.onPlaybackError?()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.handleTimeUpdate(time.seconds) }
        }

        // Start the renderer timeline once; frames are tagged relative to this.
        if !didStartSynchronizer {
            didStartSynchronizer = true
            synchronizer.setRate(1, time: .zero)
        }

        // Hand the pump everything it needs; it runs entirely off the main thread.
        let sizeCallback: @Sendable (CGSize) -> Void = { [weak self] size in
            Task { @MainActor in
                self?.knownVideoSize = size
                self?.onVideoSizeKnown?(size)
                self?.scheduleRefitBurst()
            }
        }
        // Cached depth: 60fps warp of pre-computed PTS-matched depth, no ANE.
        // Realtime: also 60fps video — RealtimeDepthSource infers at ~30Hz and
        // holds the map for the in-between frame (≤1 frame of depth age);
        // slow inference still gates its own tick, so this degrades to the
        // old 30fps cadence when the model can't keep up.
        let depthSource: PumpDepthSource?
        if let cacheEntry {
            depthSource = CachedDepthSource(entry: cacheEntry, device: warp.device)
        } else {
            depthSource = RealtimeDepthSource(device: warp.device)
        }
        guard let pump = StereoPump(
            videoRenderer: videoRenderer,
            frameSource: AVPlayerFrameSource(output: output),
            warp: warp,
            startHostTime: CACurrentMediaTime(),
            depthSource: depthSource,
            frameInterval: 1.0 / 60.0,
            onVideoSizeKnown: sizeCallback
        ) else {
            Task { @MainActor in self.onPlaybackError?() }
            return
        }
        pump.updateConfig(makePumpConfig())
        pump.start()
        self.pump = pump

        // Resume where the previous (2D) player left off when the caller says
        // so — engaging fake-3D mid-watch shouldn't restart the video.
        if let startAt, startAt > 1 { seek(to: startAt) }
        // startPaused: seek alone (paused player) still delivers the target
        // frame to the video output, so the pump warps and enqueues that one
        // frame — the video shows as a 3D still without a sustained decode
        // session. Also clear the room-resume intent (defaults true) so a room
        // activation doesn't auto-play the still we deliberately left paused;
        // a manual play() still works normally.
        if startPaused {
            wasPlayingBeforeRoomExit = false
        } else if isRoomActive {
            play()
        }
    }

    /// Mount an externally-driven frame source instead of opening a player.
    ///
    /// The browser case: the page's own `<video>` stays the decoder, the clock
    /// and the audio source, and only pixels are diverted here. No `AVPlayer`
    /// is created, which has a consequence worth stating rather than
    /// discovering — this engine then publishes **no** transport and no
    /// `RAVEPlaybackState`. `play()`/`pause()`/`seek(to:)` become no-ops
    /// (they act on a nil player) and `currentTime` reads 0. A caller that
    /// wants a scrubber drives the page and reports its own state; the engine
    /// is a display, and here it is only a display.
    ///
    /// Realtime-only by design: cached depth needs a stable per-video identity
    /// and a conversion pass up front, and arbitrary browsing has neither.
    ///
    /// - Returns: false when there is no depth model or no Metal warp — the
    ///   same "no fake-3D" answer `load(url:…)` gives, which callers already
    ///   handle by staying on the flat page.
    @discardableResult
    public func attach(frameSource: PumpFrameSource) -> Bool {
        // Fake-3D requires real depth; there is no heuristic fallback. Checked
        // before teardown so a failed attach leaves any current playback alone.
        guard Pseudo3DDiagnostics.useStaticTestPattern || CoreMLDepthProvider.hasAvailableModel(role: .realtime),
              let warp = RAVEStereoWarpResources.shared else {
            Task { @MainActor in self.onPlaybackError?() }
            return false
        }

        cleanupPlayer()
        depthMode = .realtime
        isRoomActive = true
        knownVideoSize = nil
        refitBurstTask?.cancel()

        if !didStartSynchronizer {
            didStartSynchronizer = true
            synchronizer.setRate(1, time: .zero)
        }

        let sizeCallback: @Sendable (CGSize) -> Void = { [weak self] size in
            Task { @MainActor in
                self?.knownVideoSize = size
                self?.onVideoSizeKnown?(size)
                self?.scheduleRefitBurst()
            }
        }

        guard let pump = StereoPump(
            videoRenderer: videoRenderer,
            frameSource: frameSource,
            warp: warp,
            startHostTime: CACurrentMediaTime(),
            depthSource: RealtimeDepthSource(device: warp.device),
            frameInterval: 1.0 / 60.0,
            onVideoSizeKnown: sizeCallback
        ) else {
            Task { @MainActor in self.onPlaybackError?() }
            return false
        }
        pump.updateConfig(makePumpConfig())
        pump.start()
        self.pump = pump
        return true
    }

    public func play() { isRoomActive = true; player?.play() }
    public func pause() { player?.pause() }

    public func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func setMuted(_ muted: Bool) {
        player?.isMuted = muted
        reportPlaybackState()
    }

    public func setLoopBounds(a: Double?, b: Double?) { loopA = a; loopB = b }

    public func setRoomActive(_ active: Bool) {
        guard isRoomActive != active else { return }
        isRoomActive = active
        if active {
            // Restore the state from room exit — a manual pause sticks across
            // focus/room flaps; a playing (e.g. wall-snapped) window resumes.
            if wasPlayingBeforeRoomExit { play() }
        } else {
            // `!= .paused`: a still-buffering player (.waitingToPlay…) counts
            // as playing, so the transient inactive flap at window open
            // doesn't capture it as "paused" and kill autoplay.
            wasPlayingBeforeRoomExit = player?.timeControlStatus != .paused
            pause()
        }
    }

    private func handleTimeUpdate(_ seconds: Double) {
        if let loopA, let loopB, seconds >= loopB - (1.0 / 60.0) { seek(to: loopA) }
        reportPlaybackState(currentTime: seconds)
    }

    private func reportPlaybackState(currentTime: Double? = nil) {
        guard let player else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        let ranges = player.currentItem?.loadedTimeRanges ?? []
        let buffered = ranges
            .map(\.timeRangeValue)
            .map { $0.start.seconds + $0.duration.seconds }
            .filter { $0.isFinite }
            .max() ?? 0
        if !didReportDuration, duration.isFinite, duration > 0 {
            didReportDuration = true
            onDurationKnown?(duration)
        }
        onPlaybackUpdate?(
            .init(
                currentTime: currentTime ?? player.currentTime().seconds,
                duration: duration.isFinite ? duration : 0,
                paused: player.timeControlStatus != .playing,
                muted: player.isMuted,
                buffered: buffered
            )
        )
    }

    // MARK: Cleanup

    public func cleanup() {
        sizeSubscription?.cancel()
        sizeSubscription = nil
        refitBurstTask?.cancel()
        refitBurstTask = nil
        videoEntity = nil
        lastViewBounds = nil
        tapTargetInstalled = false
        testPump?.stop()
        testPump = nil
        pump?.stop()
        pump = nil
        cleanupPlayer()
        videoRenderer.flush()
        onVideoSizeKnown = nil
        onPlaybackError = nil
        onDurationKnown = nil
        onPlaybackUpdate = nil
    }

    private func cleanupPlayer() {
        testPump?.stop()
        testPump = nil
        pump?.stop()
        pump = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        if let videoOutput { playerItem?.remove(videoOutput) }
        timeObserver = nil
        endObserver = nil
        failureObserver = nil
        player = nil
        playerItem = nil
        videoOutput = nil
        loadedURL = nil
        loopA = nil
        loopB = nil
        didReportDuration = false
    }
}

#endif
