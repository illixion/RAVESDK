/*
 Hypnos - the film player as the system's Now Playing app

 A custom player (AVSampleBufferDisplayLayer picture, PHASE or RealityKit
 sound) gets none of what AVPlayer's own UI publishes for free. Without
 it, AirPods' and the Siri Remote's system play/pause go to whichever app
 last claimed Now Playing — on an Apple TV that was Music, which then took
 the audio session and interrupted the film (tvOS 27, 2026-09-27). This
 claims it for as long as the player is showing: title and timeline for
 the system's Now Playing UI, and play, pause, ±10 s and scrubbing routed
 to `FilmPlayer`.

 The app's audio session must not be mixable while this is active: a
 session with `.mixWithOthers` can't become the Now Playing app.
 */

import Foundation
import MediaPlayer
import os

// FilmPlayer's Synchronization.Atomic; the package floor stays at macOS 14.
@available(macOS 15.0, *)
@MainActor
public final class FilmNowPlaying {
    private let player: FilmPlayer
    private var title: String
    private var registered: [(MPRemoteCommand, Any)] = []
    private var publishTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.illixion.hypnos", category: "FilmNowPlaying")
    /// Called with each remote command's name as it arrives, for a host's
    /// own diagnostics.
    public var onCommand: ((String) -> Void)?

    public init(player: FilmPlayer, title: String) {
        self.player = player
        self.title = title
    }

    public func setTitle(_ title: String) {
        self.title = title
        publish()
    }

    public func activate() {
        guard registered.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { player in
            player.play()
            return .success
        }
        // The system picks play or pause from whether the app is making
        // sound, and can send pause to a player that is already paused
        // (measured on tvOS while PHASE rendered silence). A pause that finds
        // nothing playing resumes, so the button never goes dead.
        add(center.pauseCommand) { player in
            player.isPlaying ? player.pause() : player.play()
            return .success
        }
        add(center.togglePlayPauseCommand) { player in
            player.isPlaying ? player.pause() : player.play()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { player in
            player.seek(to: player.currentTime + 10)
            return .success
        }
        add(center.skipBackwardCommand) { player in
            player.seek(to: player.currentTime - 10)
            return .success
        }
        registered.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.seek(to: event.positionTime)
            return .success
        }))
        for (command, _) in registered { command.isEnabled = true }

        // FilmPlayer's clock isn't observable; publish it once a second,
        // which also carries play/pause changes made from inside the app.
        publishTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.publish()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func deactivate() {
        publishTask?.cancel()
        publishTask = nil
        for (command, target) in registered { command.removeTarget(target) }
        registered.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (FilmPlayer) -> MPRemoteCommandHandlerStatus) {
        let target = command.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let name = Self.name(of: event.command)
            self.logger.info("Remote command: \(name, privacy: .public)")
            self.onCommand?(name)
            return action(self.player)
        }
        registered.append((command, target))
    }

    private static func name(of command: MPRemoteCommand) -> String {
        let center = MPRemoteCommandCenter.shared()
        switch command {
        case center.playCommand: return "play"
        case center.pauseCommand: return "pause"
        case center.togglePlayPauseCommand: return "togglePlayPause"
        case center.skipForwardCommand: return "skipForward"
        case center.skipBackwardCommand: return "skipBackward"
        default: return String(describing: type(of: command))
        }
    }

    private func publish() {
        guard !registered.isEmpty else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
        #endif
    }
}
