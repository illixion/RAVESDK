/*
 RAVEFilm - the system's Picture in Picture for the film player

 iOS, iPadOS, macOS and tvOS float a picture over other apps through
 `AVPictureInPictureController`. The film's picture is its own
 `AVSampleBufferDisplayLayer` on the film clock, so the controller takes it
 as a sample-buffer content source and asks this class, as its playback
 delegate, for the timeline and to play, pause and skip: all of it goes to
 `FilmPlayer`, which keeps the object audio with the picture. The sound
 plays on while the app is away only if the app may play in the background
 (`UIBackgroundModes` audio on iOS and tvOS).

 visionOS has no system Picture in Picture for a custom player; Hypnos's
 Cinema HUD stands in for it there.
 */

#if os(iOS) || os(macOS) || os(tvOS)
import AVFoundation
import AVKit
import CoreMedia
import DebugLog
import Observation

@available(macOS 15.0, *)
@MainActor
@Observable
public final class FilmPictureInPicture: NSObject {
    /// The system can float the picture now.
    public private(set) var isPossible = false
    /// The picture floats over other apps.
    public private(set) var isActive = false
    @ObservationIgnored private let player: FilmPlayer
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "FilmPlayer")

    public init(player: FilmPlayer) {
        self.player = player
        super.init()
    }

    /// Starts offering Picture in Picture for the player's picture. Call once
    /// its display layer is in a window.
    public func activate() {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: player.video.displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observed, _ in
            let possible = observed.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                if self?.isPossible != possible { self?.isPossible = possible }
            }
        }
        self.controller = controller
        // The controller reads play/pause and the timeline only when told
        // they changed.
        stateTask = Task { @MainActor [weak self] in
            var last: (Bool, Double)?
            while !Task.isCancelled, let self {
                let state = (self.player.isPlaying, self.player.duration)
                if last.map({ $0 != state }) ?? true {
                    last = state
                    self.controller?.invalidatePlaybackState()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    public func deactivate() {
        stop()
        stateTask?.cancel()
        stateTask = nil
        possibleObservation = nil
        controller = nil
        isPossible = false
        isActive = false
    }

    public func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    public func stop() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }
}

@available(macOS 15.0, *)
extension FilmPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated public func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated { playing ? player.play() : player.pause() }
    }

    nonisolated public func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            let duration = player.duration
            // Unknown yet: an open-ended range, which the system shows as live.
            guard duration > 0 else { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
            return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        }
    }

    nonisolated public func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { !player.isPlaying }
    }

    nonisolated public func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                       didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated public func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                       skipByInterval skipInterval: CMTime,
                                                       completion completionHandler: @escaping @Sendable () -> Void) {
        MainActor.assumeIsolated {
            player.seek(to: player.currentTime + skipInterval.seconds)
        }
        completionHandler()
    }
}

@available(macOS 15.0, *)
extension FilmPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated public func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            logger.info("Picture in Picture starting")
            isActive = true
        }
    }

    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            logger.info("Picture in Picture stopped")
            isActive = false
        }
    }

    nonisolated public func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                       failedToStartPictureInPictureWithError error: any Error) {
        MainActor.assumeIsolated {
            logger.error("Picture in Picture failed to start: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            isActive = false
        }
    }

    // The player is still there under the floating picture: nothing to restore.
    nonisolated public func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                       restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
#endif
