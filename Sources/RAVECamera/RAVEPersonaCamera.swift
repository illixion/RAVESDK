/*
 RAVECamera - the Persona camera, raw.

 On visionOS the only capture device an app is ever offered is the wearer's
 Persona, and it is worth knowing what each way of reaching it returns —
 because they are not the same picture:

 - **`AVCaptureSession`, here,** delivers the device's native format: a
   landscape 1920×1080 frame with the Persona composited into it. This is
   what Longwave's Broadcast tab streams.
 - **WebKit's `getUserMedia`** delivers the same sensor through its own
   media-capture layer, which reframes around the wearer (Center Stage-style)
   before the page ever sees a pixel. Measured from a WKWebView: a 16:9 ask
   comes back **720×1280 portrait** with empty bands top and bottom, and an ask
   with no aspect constraint comes back **1080×1080**. The full landscape
   frame is never offered to a page.

 So an app that wants the frame the sensor actually produces has to own the
 capture session itself, and this class is that session. It is a convergence
 of Longwave's `BroadcastCaptureSession` (the original) and the native path
 Raven's camera proxy needed for exactly the reason above.

 visionOS exposes a reduced AVCapture surface — no session presets, no
 `AVCaptureAudioDataOutput` — so video comes from `AVCaptureVideoDataOutput`
 at the device's native format and the microphone, when wanted, is the
 caller's business (Longwave taps `AVAudioEngine` for it).

 The camera is device-exclusive across processes. WebKit's own capture runs
 in a separate process, so a page holding the camera through `getUserMedia`
 and this session cannot both have it: whichever starts second is interrupted
 with `videoDeviceInUseByAnotherClient`. A caller replacing WebKit's capture
 must stop the page's track *first*.
 */

import AVFoundation
import CoreMedia
import Foundation

public final class RAVEPersonaCamera: NSObject, @unchecked Sendable {

    /// Every video frame, on a dedicated high-priority queue. Late frames are
    /// dropped by the output rather than queued — an encoder downstream must
    /// never see latency snowball.
    public var onVideoSample: ((CMSampleBuffer) -> Void)?
    /// The OS took the camera away: another client claimed it, the app left the
    /// foreground, system pressure. The session resumes on its own when the
    /// interruption ends; this exists so a caller can *say* why frames stopped.
    /// Never fires on macOS, which has no interruption model.
    public var onInterruptionBegan: ((String) -> Void)?
    public var onInterruptionEnded: (() -> Void)?
    /// The session failed and will not deliver again without being restarted.
    public var onRuntimeError: ((String) -> Void)?

    /// Exposed for a host's preview layer or diagnostics. Configure, start and
    /// stop only through this class.
    public let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.illixion.ravecamera.session")
    private let videoQueue = DispatchQueue(label: "com.illixion.ravecamera.video", qos: .userInteractive)
    private var observers: [NSObjectProtocol] = []

    public override init() {
        super.init()
        observeSession()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Every video capture device the OS will give this app. The device types
    /// Persona enumerates as are undocumented, so discovery is merged with the
    /// system default and what was found is logged. On visionOS this is one
    /// entry — "Front Camera" — and "Mirror My View" is deliberately absent:
    /// it is not a capture device at all, only a ReplayKit broadcast source.
    public static func availableCameras() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video, position: .unspecified)
        var devices = discovery.devices
        if let fallback = AVCaptureDevice.default(for: .video),
           !devices.contains(where: { $0.uniqueID == fallback.uniqueID }) {
            devices.append(fallback)
        }
        for device in devices {
            RAVECameraLog.capture.info("""
            video device: \(device.localizedName, privacy: .public) \
            [\(device.uniqueID, privacy: .public)] type=\(device.deviceType.rawValue, privacy: .public)
            """)
        }
        return devices
    }

    public enum ConfigurationError: Error, LocalizedError {
        case inputRejected(String)

        public var errorDescription: String? {
            switch self {
            case .inputRejected(let detail): "Capture setup failed: \(detail)"
            }
        }
    }

    /// Replaces every input and output with this camera and one NV12 video
    /// output. Safe to call on a stopped or running session.
    public func configure(camera: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        do {
            let videoInput = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(videoInput) else {
                throw ConfigurationError.inputRejected("video input not accepted")
            }
            session.addInput(videoInput)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.inputRejected(error.localizedDescription)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        // NV12 is VideoToolbox's preferred input; drop late frames rather
        // than letting encode latency snowball.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else {
            throw ConfigurationError.inputRejected("video output not accepted")
        }
        session.addOutput(videoOutput)
    }

    /// Starts delivering frames. Asynchronous: `startRunning` blocks for as
    /// long as the hardware takes, which is not something to do on the caller's
    /// thread.
    public func start() {
        sessionQueue.async { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    public func stop() {
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let description = error?.localizedDescription ?? "unknown"
            RAVECameraLog.capture.error("capture session runtime error: \(description, privacy: .public)")
            self?.onRuntimeError?(description)
        })
        #if os(iOS) || os(visionOS)
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] notification in
            let reason = Self.describeInterruption(notification)
            RAVECameraLog.capture.info("capture interrupted: \(reason, privacy: .public)")
            self?.onInterruptionBegan?(reason)
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            RAVECameraLog.capture.info("capture interruption ended")
            self?.onInterruptionEnded?()
        })
        #endif
    }

    #if os(iOS) || os(visionOS)
    private static func describeInterruption(_ notification: Notification) -> String {
        guard let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else { return "unknown reason" }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "app is in the background"
        case .audioDeviceInUseByAnotherClient: return "audio device in use by another client"
        case .videoDeviceInUseByAnotherClient: return "camera in use by another client"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "camera unavailable with multiple foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure: return "camera unavailable due to system pressure"
        case .sensitiveContentMitigationActivated: return "sensitive content mitigation activated"
        @unknown default: return "reason \(raw)"
        }
    }
    #endif
}

extension RAVEPersonaCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        onVideoSample?(sampleBuffer)
    }
}
