/*
 RAVEMedia - spatial-audio policy for AVPlayer-backed playback.

 Moved out of Spatial Stash's `AudioSessionConfig` because the stereo engine
 applies it to every player it creates, and the reasoning below is device-paid
 rather than app-specific. What stayed behind is the *session* category
 (`.playback` + `.mixWithOthers`), which is a whole-app decision about stealing
 audio focus and belongs to whoever owns the app lifecycle.
 */

#if os(visionOS)

import AudioToolbox
import AVFoundation
import CoreMedia
import os

extension AVPlayerItem {
    /// Apply the spatial-audio policy: spatialize only genuine multichannel
    /// (5.1/7.1) audio, and play mono/stereo non-spatialized.
    ///
    /// visionOS defaults video items to `.monoStereoAndMultichannel`, so it
    /// head-tracks even plain stereo — anchoring the sound to a window position
    /// that frequently reads as "coming from the wrong window" when several
    /// player windows are open. Restricting to `.multichannel` bypasses that
    /// for stereo while retaining head-tracked spatial audio for true surround.
    /// AVFoundation makes the stereo-vs-surround decision from the decoded
    /// channel layout, so no manual channel counting is needed. (The user can
    /// still override globally via Control Center.)
    ///
    /// Call once per item right after creation. Not KVO-compliant, so setting
    /// it eagerly (before playback) is the intended usage.
    public func applySpatialAudioPolicy() {
        guard !RAVEMediaPolicy.spatializeStereo else { return }
        allowedAudioSpatializationFormats = .multichannel
    }
}

extension AVPlayer {
    /// Apply the spatial-audio policy at the player level, which is what
    /// actually governs visionOS window-anchored spatialization (the item's
    /// `allowedAudioSpatializationFormats` only gates the stereo→spatial upmix,
    /// not the anchoring that makes audio seem to come from the wrong window).
    ///
    /// visionOS 26 defaults a player to `CAAutomaticSpatialAudio`, which
    /// spatializes even plain stereo and anchors it to a window position — often
    /// the wrong one with several player windows open. This bypasses
    /// spatialization for mono/stereo and keeps head-tracked spatial audio for
    /// genuine multichannel (5.1/7.1). Being per-player (not the process-global
    /// `AVAudioSession` intended experience), simultaneous stereo and surround
    /// windows each behave correctly.
    ///
    /// `.bypassed` is applied immediately (fixes the common stereo case with no
    /// startup race); the policy upgrades to `.headTracked` once the audio is
    /// confirmed multichannel. Confirmation is layered because no single probe
    /// covers every source: file tracks, then HLS variant/rendition channel
    /// counts, then (HLS media playlists such as Jellyfin's `main.m3u8` expose
    /// neither) the item's own tracks once it is `.readyToPlay`. The last
    /// probe is why a surround HLS stream no longer stays pinned to
    /// `.bypassed` — the asset-level track load alone returns nothing for it.
    ///
    /// Genuine multichannel is head-tracked, or head-locked (`.fixed`) under
    /// `RAVEMediaPolicy.headLockedSurround`, which a live player follows.
    public func applySpatialAudioPolicy(for asset: AVURLAsset) {
        RAVESpatialAudioPlayers.register(self)
        guard !RAVEMediaPolicy.spatializeStereo else {
            if RAVEMediaPolicy.headLockedSurround { intendedSpatialAudioExperience = .fixed(soundStageSize: .automatic) }
            return
        }
        intendedSpatialAudioExperience = .bypassed
        let item = currentItem
        Task { [weak self] in
            let surround = await asset.detectMultichannelAudio(item: item)
            guard surround, let self, self.currentItem === item else { return }
            self.intendedSpatialAudioExperience = RAVESpatialAudioPlayers.surroundExperience
        }
    }

    /// Re-applies the surround policy after `RAVEMediaPolicy.headLockedSurround`
    /// changed. Bypassed (stereo) players stay bypassed.
    fileprivate func refreshSurroundAnchoring() {
        guard !(intendedSpatialAudioExperience is BypassedSpatialAudio) else { return }
        intendedSpatialAudioExperience = RAVESpatialAudioPlayers.surroundExperience
    }
}

/// Every player the policy was applied to, weakly, so a change of
/// `RAVEMediaPolicy.headLockedSurround` reaches the ones playing.
enum RAVESpatialAudioPlayers {
    private static let players = OSAllocatedUnfairLock(uncheckedState: NSHashTable<AVPlayer>.weakObjects())

    static var surroundExperience: any SpatialAudioExperience {
        if RAVEMediaPolicy.headLockedSurround { return .fixed(soundStageSize: .automatic) }
        return RAVEMediaPolicy.spatializeStereo
            ? AutomaticSpatialAudio.automatic
            : .headTracked(.automatic, soundStageSize: .automatic)
    }

    static func register(_ player: AVPlayer) {
        players.withLockUnchecked { _ = $0.add(player) }
    }

    static func refreshSurroundAnchoring() {
        let live = players.withLockUnchecked { $0.allObjects }
        for player in live { player.refreshSurroundAnchoring() }
    }
}

extension AVURLAsset {
    /// True if any audio track carries more than two channels (5.1/7.1, etc.).
    /// Only sees tracks the asset exposes directly, so it misses HLS; use
    /// `detectMultichannelAudio(item:)` when the source may be a stream.
    public func hasMultichannelAudio() async throws -> Bool {
        for track in try await loadTracks(withMediaType: .audio) {
            if try await track.hasMultichannelFormat() { return true }
        }
        return false
    }

    /// True if HLS variant metadata declares a rendition with more than two
    /// channels. Needs a master playlist; a bare media playlist has no variants.
    func hasMultichannelVariant() async -> Bool {
        guard let variants = try? await load(.variants), !variants.isEmpty else { return false }
        let group = try? await loadMediaSelectionGroup(for: .audible)
        for variant in variants {
            guard let audio = variant.audioAttributes else { continue }
            for option in group?.options ?? [] {
                if let rendition = audio.renditionSpecificAttributes(for: option), (rendition.channelCount ?? 0) > 2 {
                    return true
                }
            }
        }
        return false
    }

    /// Layered multichannel detection: see `AVPlayer.applySpatialAudioPolicy(for:)`.
    /// When `item` is given and nothing earlier answers, waits (bounded) for it to
    /// become ready and inspects its tracks.
    func detectMultichannelAudio(item: AVPlayerItem?) async -> Bool {
        if (try? await hasMultichannelAudio()) == true { return true }
        if await hasMultichannelVariant() { return true }
        guard let item else { return false }
        guard await item.waitUntilReady(timeout: 30) else { return false }
        if await item.hasMultichannelItemTrack() { return true }
        // Tracks of an HLS asset often only resolve once the item is playing it.
        return (try? await hasMultichannelAudio()) == true
    }
}

extension AVAssetTrack {
    fileprivate func hasMultichannelFormat() async throws -> Bool {
        for desc in try await load(.formatDescriptions) {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
               asbd.mChannelsPerFrame > 2 {
                return true
            }
        }
        return false
    }
}

extension AVPlayerItem {
    @MainActor
    fileprivate func hasMultichannelItemTrack() async -> Bool {
        for itemTrack in tracks {
            guard let track = itemTrack.assetTrack, track.mediaType == .audio else { continue }
            if (try? await track.hasMultichannelFormat()) == true { return true }
        }
        return false
    }

    /// Resolves true once the item reports `.readyToPlay`, false on failure or timeout.
    fileprivate func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch status {
            case .readyToPlay: return true
            case .failed: return false
            default: try? await Task.sleep(for: .milliseconds(200))
            }
            if Task.isCancelled { return false }
        }
        return false
    }
}

#endif
