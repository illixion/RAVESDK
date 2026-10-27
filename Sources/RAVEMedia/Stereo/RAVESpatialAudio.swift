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
    /// Apply the spatial-audio policy. When a custom-rendered video has an
    /// owning scene, permit all channel layouts so its stereo and surround
    /// audio can be anchored to that scene. Else preserve the app's default
    /// of spatializing only true multichannel audio.
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
    public func applySpatialAudioPolicy(sceneIdentifier: String? = nil) {
        guard !RAVEMediaPolicy.spatializeStereo else { return }
        allowedAudioSpatializationFormats = sceneIdentifier == nil ? .multichannel : .monoStereoAndMultichannel
    }
}

extension AVPlayer {
    /// Apply the spatial-audio policy at the player level, which is what
    /// actually governs visionOS window-anchored spatialization (the item's
    /// `allowedAudioSpatializationFormats` only gates the stereo→spatial upmix,
    /// not the anchoring that makes audio seem to come from the wrong window).
    ///
    /// A custom Metal player doesn't provide AVPlayer with a visual counterpart
    /// for automatic anchoring. When given the owning scene ID, this explicitly
    /// anchors mono/stereo and surround sound to that scene; otherwise it keeps
    /// the prior bypass for mono/stereo and head-tracks genuine multichannel.
    ///
    /// The scene anchor (or bypass without a scene ID) is applied immediately;
    /// when there is no scene ID, the policy upgrades once audio is confirmed
    /// multichannel. Confirmation is layered because no single probe
    /// covers every source: file tracks, then HLS variant/rendition channel
    /// counts, then (HLS media playlists such as Jellyfin's `main.m3u8` expose
    /// neither) the item's own tracks once it is `.readyToPlay`. The last
    /// probe is why a surround HLS stream doesn't stay in its initial mode —
    /// the asset-level track load alone returns nothing for it.
    ///
    /// Genuine multichannel is head-tracked, or head-locked (`.fixed`) under
    /// `RAVEMediaPolicy.headLockedSurround`, which a live player follows.
    public func applySpatialAudioPolicy(for asset: AVURLAsset, sceneIdentifier: String? = nil) {
        RAVESpatialAudioPlayers.register(self, sceneIdentifier: sceneIdentifier)
        if RAVEMediaPolicy.headLockedSurround && RAVEMediaPolicy.spatializeStereo {
            intendedSpatialAudioExperience = .fixed(soundStageSize: .automatic)
        } else if RAVEMediaPolicy.headLockedSurround {
            // Head-locked sound is for surround. Stereo stays unspatialized
            // even in a custom-rendered window, or it would still be anchored
            // to that scene; genuine multichannel upgrades to `.fixed` below.
            intendedSpatialAudioExperience = .bypassed
        } else if let sceneIdentifier {
            // Custom Metal rendering doesn't give AVPlayer a visual view to
            // anchor against. Name the window explicitly so concurrent
            // players don't all anchor their sound to the first scene.
            intendedSpatialAudioExperience = .headTracked(.scene(identifier: sceneIdentifier), soundStageSize: .automatic)
        } else if !RAVEMediaPolicy.spatializeStereo {
            intendedSpatialAudioExperience = .bypassed
        }
        guard !RAVEMediaPolicy.spatializeStereo else { return }
        let item = currentItem
        Task { [weak self] in
            let found = await asset.detectMultichannelAudio(item: item)
            guard let self, self.currentItem === item else { return }
            guard let found else {
                RAVEMediaLog.spatialAudio.info(sceneIdentifier == nil
                    ? "Stereo or mono: spatial audio bypassed"
                    : "Stereo or mono: audio anchored to its scene")
                return
            }
            RAVESpatialAudioPlayers.markMultichannel(self)
            self.intendedSpatialAudioExperience = RAVESpatialAudioPlayers.surroundExperience(sceneIdentifier: sceneIdentifier)
            RAVEMediaLog.spatialAudio.info("Multichannel (\(found, privacy: .public)): \(RAVEMediaPolicy.headLockedSurround ? "head-locked" : "head-tracked", privacy: .public) spatial audio")
        }
    }

    /// Re-applies the surround policy after `RAVEMediaPolicy.headLockedSurround`
    /// changed. Bypassed (stereo) players stay bypassed, except that a stereo
    /// player anchored to its scene is bypassed once sound is head-locked and
    /// re-anchored when it is not.
    fileprivate func refreshSurroundAnchoring(multichannel: Bool) {
        let sceneIdentifier = RAVESpatialAudioPlayers.sceneIdentifier(for: self)
        if multichannel || RAVEMediaPolicy.spatializeStereo {
            guard !(intendedSpatialAudioExperience is BypassedSpatialAudio) else { return }
            intendedSpatialAudioExperience = RAVESpatialAudioPlayers.surroundExperience(sceneIdentifier: sceneIdentifier)
        } else if RAVEMediaPolicy.headLockedSurround {
            intendedSpatialAudioExperience = .bypassed
        } else if let sceneIdentifier {
            intendedSpatialAudioExperience = .headTracked(.scene(identifier: sceneIdentifier), soundStageSize: .automatic)
        }
    }
}

/// Every player the policy was applied to, weakly, so a change of
/// `RAVEMediaPolicy.headLockedSurround` reaches the ones playing.
enum RAVESpatialAudioPlayers {
    private static let players = OSAllocatedUnfairLock(uncheckedState: NSHashTable<AVPlayer>.weakObjects())
    private static let sceneIdentifiers = OSAllocatedUnfairLock(uncheckedState: [ObjectIdentifier: String]())
    private static let multichannelPlayers = OSAllocatedUnfairLock(uncheckedState: Set<ObjectIdentifier>())

    static func surroundExperience(sceneIdentifier: String? = nil) -> any SpatialAudioExperience {
        if RAVEMediaPolicy.headLockedSurround { return .fixed(soundStageSize: .automatic) }
        if let sceneIdentifier { return .headTracked(.scene(identifier: sceneIdentifier), soundStageSize: .automatic) }
        return RAVEMediaPolicy.spatializeStereo
            ? AutomaticSpatialAudio.automatic
            : .headTracked(.automatic, soundStageSize: .automatic)
    }

    static func register(_ player: AVPlayer, sceneIdentifier: String?) {
        players.withLockUnchecked { _ = $0.add(player) }
        let identifier = ObjectIdentifier(player)
        let liveIDs = Set(players.withLockUnchecked { $0.allObjects.map(ObjectIdentifier.init) })
        sceneIdentifiers.withLockUnchecked { values in
            values = values.filter { liveIDs.contains($0.key) }
            if let sceneIdentifier { values[identifier] = sceneIdentifier }
            else { values.removeValue(forKey: identifier) }
        }
        multichannelPlayers.withLockUnchecked { values in
            values = values.intersection(liveIDs)
            values.remove(identifier)
        }
    }

    static func markMultichannel(_ player: AVPlayer) {
        multichannelPlayers.withLockUnchecked { $0.insert(ObjectIdentifier(player)) }
    }

    static func sceneIdentifier(for player: AVPlayer) -> String? {
        sceneIdentifiers.withLockUnchecked { $0[ObjectIdentifier(player)] }
    }

    static func refreshSurroundAnchoring() {
        let live = players.withLockUnchecked { $0.allObjects }
        let liveIDs = Set(live.map(ObjectIdentifier.init))
        sceneIdentifiers.withLockUnchecked { values in values = values.filter { liveIDs.contains($0.key) } }
        multichannelPlayers.withLockUnchecked { values in values = values.intersection(liveIDs) }
        let multichannel = multichannelPlayers.withLockUnchecked { $0 }
        for player in live {
            player.refreshSurroundAnchoring(multichannel: multichannel.contains(ObjectIdentifier(player)))
        }
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
    /// become ready and inspects its tracks. Names the probe that found it; nil
    /// when none did.
    func detectMultichannelAudio(item: AVPlayerItem?) async -> String? {
        if (try? await hasMultichannelAudio()) == true { return "file track" }
        if await hasMultichannelVariant() { return "HLS rendition" }
        guard let item else { return nil }
        guard await item.waitUntilReady(timeout: 30) else { return nil }
        if await item.hasMultichannelItemTrack() { return "item track" }
        // Tracks of an HLS asset often only resolve once the item is playing it.
        return (try? await hasMultichannelAudio()) == true ? "file track, once ready" : nil
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
