/*
 RAVECamera - the Persona as a camera feed, for a camera proxy.

 WebKit's `getUserMedia` never hands a page the frame the Persona camera
 actually produces. Its capture layer reframes the sensor around the wearer
 before the page sees a pixel: a 16:9 ask comes back 720×1280 portrait, an
 unconstrained ask comes back 1080×1080, and the native 1920×1080 landscape
 frame — the one Longwave's Broadcast tab streams straight out of
 `AVCaptureSession` — is not on offer at all. So when a proxy wants that
 frame, the app captures it itself, here, and feeds it to the page as encoded
 access units (see `codec`) the page's `VideoDecoder` paints into the proxy
 canvas.

 `RAVEPersonaCamera` + `RAVEH264Encoder` do the work; this owns the order of
 operations and the one-shot ending. It runs off the main actor entirely:
 capture frames arrive on the camera's queue, access units on VideoToolbox's
 output thread, and RAVEBrowser's `RAVECameraProxy` hops each callback onto
 the main actor itself, in order.

 **The camera is device-exclusive, and WebKit's capture is another process.**
 The page script stops WebKit's video track *before* asking for this, and the
 proxy allows one live Persona feed per process; either being wrong shows up
 as an immediate `videoDeviceInUseByAnotherClient` interruption and a black
 proxy.

 Raven's `NativeCameraFeed`, lifted 2026-10-17 with the proxy.
 */

import AVFoundation
import Foundation

public final class RAVEPersonaCameraFeed: RAVECameraFeed, @unchecked Sendable {
    /// Codec string plus the `avcC`/`hvcC` record, once up front and again
    /// only if they change — the page decoder's `codec` and `description`,
    /// exactly as VideoToolbox built them — with the frame size the encoder
    /// was created for, which the record does not state and a format
    /// description built from it needs.
    public nonisolated(unsafe) var onDecoderConfiguration: (@Sendable (
        RAVEH264Encoder.DecoderConfiguration, _ width: Int, _ height: Int
    ) -> Void)?
    /// Every captured frame, uncompressed, on the camera's queue, before it
    /// goes to the encoder. A preview's live layer hangs off this; nothing
    /// else should, and it must return quickly. Set before `start()`.
    public nonisolated(unsafe) var onVideoSample: (@Sendable (CMSampleBuffer) -> Void)?
    /// One access unit per frame, timestamps rebased to the first frame in
    /// microseconds — `EncodedVideoChunk`'s conventional shape.
    ///
    /// `capturedAtMs` and `encodedAtMs` are wall-clock epoch milliseconds: when
    /// the sensor produced the frame and when the encoder handed it back. Wall
    /// clock rather than host time because the page reads `Date.now()` from
    /// another process, and the epoch is the one clock both sides share. The
    /// capture time is derived from the sample's host-clock PTS; if that ever
    /// reads implausibly (outside 0–5 s of encode latency) both are `nan`, so a
    /// latency report says "unknown" rather than a number nobody should trust.
    public nonisolated(unsafe) var onAccessUnit: (@Sendable (
        _ avcc: Data, _ ptsMicroseconds: UInt64, _ keyframe: Bool,
        _ capturedAtMs: Double, _ encodedAtMs: Double
    ) -> Void)?
    /// One shot: access refused, no device, configuration rejected, encoder or
    /// session failure. Not fired by `stop()`.
    public nonisolated(unsafe) var onEnded: (@Sendable (String) -> Void)?

    /// 1080p30 through a loopback relay. The published track is downscaled
    /// into a 720p send tier anyway, so this only has to be clean enough that
    /// the page's decode is not the weakest link; 6 Mbit/s of base64 through
    /// the JS bridge is under what Raven's screen-share relay already moves.
    public static let bitrate = 6_000_000
    /// Natural GOP. Two seconds is a balance between two costs that pull in
    /// opposite directions. Longer was better for the page: a keyframe at this
    /// bitrate is several hundred kilobytes the page has to take in one go,
    /// and it used to be 4 s for that reason (joining and recovery never wait
    /// for it — the relay asks for a keyframe the moment it needs one). Shorter
    /// is better for Raven's replay reverse pass, which holds one decoded GOP in
    /// memory at a time: 60 frames of NV12 1080p is ~190 MB at the peak, 4 s
    /// would be double that. Since chunks now cross the bridge as
    /// `callAsyncJavaScript` arguments rather than parsed source, the page's
    /// side of that trade is far cheaper than when 4 s was chosen.
    public static let keyframeInterval: TimeInterval = 2
    /// For HEVC this maps to Main regardless. It is `.baseline` because that
    /// is what the H.264 leg of the latency investigation ended on, and it is
    /// the right H.264 choice if `codec` is ever switched back: measured on
    /// device, Main and Baseline decoded with the *same* 135 ms hold inside
    /// WebKit's `VideoDecoder` (four frame periods, its input queue empty), so
    /// no H.264 profile talks the decoder out of waiting for the level's whole
    /// decoded-picture buffer. The codec does — see `codec`.
    public static let profile: RAVEH264Encoder.Profile = .baseline
    /// HEVC, and the reason is decode latency rather than bitrate: the bridge
    /// moved the 6 Mbit/s H.264 stream in ~1 ms, so bytes were never the cost.
    /// An H.264 SPS may omit the reorder depth and VideoToolbox's does, so
    /// WebKit's decoder held every frame for the level's full decoded-picture
    /// buffer in case B-frames followed — 135 ms at 1080p, with
    /// `optimizeForLatency` making no difference. An HEVC SPS must state
    /// `sps_max_num_reorder_pics`, VideoToolbox writes 0 there with reordering
    /// off, and the same decoder then emits each frame as it lands: measured
    /// 2–3 ms, sensor-to-canvas total 175 → ~45 ms. WebKit accepts the
    /// `hvc1.1.6.L120.B0` string and the `hvcC` record verbatim.
    public static let codec: RAVEH264Encoder.Codec = .hevc

    /// The encoder settings above, as one value: what an app re-encoding this
    /// feed's frames (Raven's reversed replay half) builds its encoder with,
    /// so the two streams decode alike.
    public static var encoderConfiguration: RAVEH264Encoder.Configuration {
        .init(bitrate: bitrate, keyframeInterval: keyframeInterval, profile: profile, codec: codec)
    }

    private let camera = RAVEPersonaCamera()
    private let encoder = RAVEH264Encoder(configuration: RAVEPersonaCameraFeed.encoderConfiguration)
    private let queue = DispatchQueue(label: "com.illixion.rave.camera.personafeed")
    private nonisolated(unsafe) var clock = RAVEMicrosecondClock()
    private nonisolated(unsafe) var ended = false
    /// The size of the frames the encoder has been fed, read on the capture
    /// queue and reported with the configuration — which VideoToolbox emits
    /// only after the first frame, so it is always set by then.
    private nonisolated(unsafe) var frameSize = (width: 0, height: 0)

    deinit { RAVELiveObjects.release("RAVEPersonaCameraFeed") }

    public init() {
        RAVELiveObjects.retain("RAVEPersonaCameraFeed")
        encoder.onDecoderConfiguration = { [weak self] config in
            guard let self else { return }
            self.onDecoderConfiguration?(config, self.frameSize.width, self.frameSize.height)
        }
        encoder.onAccessUnit = { [weak self] unit in
            guard let self, let micros = self.clock.microseconds(for: unit.presentationTime) else { return }
            // The capture PTS is on the host clock (AVCaptureSession's default
            // synchronization clock), so "now minus PTS" is the frame's age
            // and pins its capture instant onto the wall clock.
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let ageSeconds = hostNow - unit.presentationTime.seconds
            let wallNowMs = Date().timeIntervalSince1970 * 1000
            let plausible = ageSeconds >= 0 && ageSeconds < 5
            let capturedAtMs = plausible ? wallNowMs - ageSeconds * 1000 : .nan
            self.onAccessUnit?(unit.data, micros, unit.isKeyframe, capturedAtMs, plausible ? wallNowMs : .nan)
        }
        encoder.onError = { [weak self] message in
            self?.finish("encoder: \(message)")
        }
        camera.onVideoSample = { [weak self] sample in
            guard let self else { return }
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                self.frameSize = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
            }
            self.onVideoSample?(sample)
            self.encoder.encode(sample)
        }
        camera.onRuntimeError = { [weak self] message in
            self?.finish("capture session failed: \(message)")
        }
        // Interruptions resume on their own (the app returning to the
        // foreground, another client releasing the camera), so they are said,
        // not acted on. The page keeps its proxy track throughout; frames
        // simply pause.
        camera.onInterruptionBegan = { reason in
            RAVECameraLog.capture.info("persona feed interrupted: \(reason, privacy: .public)")
        }
        camera.onInterruptionEnded = {
            RAVECameraLog.capture.info("persona feed resumed")
        }
    }

    /// Asks for camera access if the app has never been asked, then starts
    /// capture. The app's own permission prompt is the second consent in this
    /// path — WebKit's per-site prompt already happened, since the page script
    /// only requests native capture after a real `getUserMedia` grant.
    public func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { self.run() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    if granted { self.run() } else { self.finish("camera access was denied") }
                }
            }
        default:
            finish("camera access is denied for this app — allow it in Settings")
        }
    }

    /// The next frame out of the encoder will be a keyframe. For the relay:
    /// when it has had to drop a delta, this is what lets it resume on the
    /// next frame rather than up to `keyframeInterval` later.
    public func requestKeyframe() {
        encoder.requestKeyframe()
    }

    /// Deliberate teardown. Does not fire `onEnded`.
    public func stop() {
        ended = true
        camera.stop()
        encoder.invalidate()
    }

    private func run() {
        guard !ended else { return }
        guard let device = RAVEPersonaCamera.availableCameras().first else {
            finish("no camera available")
            return
        }
        do {
            try camera.configure(camera: device)
        } catch {
            finish(error.localizedDescription)
            return
        }
        camera.start()
    }

    private func finish(_ reason: String) {
        guard !ended else { return }
        ended = true
        camera.stop()
        encoder.invalidate()
        onEnded?(reason)
    }
}
