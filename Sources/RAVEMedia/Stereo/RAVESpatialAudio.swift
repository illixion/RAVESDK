/*
 RAVEMedia - spatial-audio policy for AVPlayer-backed playback.

 Moved out of Spatial Stash's `AudioSessionConfig` because the stereo engine
 applies it to every player it creates, and the reasoning below is device-paid
 rather than app-specific. What stayed behind is the *session* category
 (`.playback` + `.mixWithOthers`), which is a whole-app decision about stealing
 audio focus and belongs to whoever owns the app lifecycle.
 */

#if os(visionOS)

import AVFoundation
import CoreMedia

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
    /// startup race); the policy upgrades to `.headTracked` only once the
    /// asset's audio is confirmed multichannel.
    public func applySpatialAudioPolicy(for asset: AVURLAsset) {
        intendedSpatialAudioExperience = .bypassed
        Task { [weak self] in
            guard let surround = try? await asset.hasMultichannelAudio(), surround else { return }
            await MainActor.run {
                self?.intendedSpatialAudioExperience = .headTracked(.automatic, soundStageSize: .automatic)
            }
        }
    }
}

extension AVURLAsset {
    /// True if any audio track carries more than two channels (5.1/7.1, etc.).
    public func hasMultichannelAudio() async throws -> Bool {
        for track in try await loadTracks(withMediaType: .audio) {
            for desc in try await track.load(.formatDescriptions) {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
                   asbd.mChannelsPerFrame > 2 {
                    return true
                }
            }
        }
        return false
    }
}

#endif
