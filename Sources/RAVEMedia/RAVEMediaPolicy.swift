/*
 RAVEMedia - host-supplied policy.

 What the player needs but cannot decide for itself, because the answer
 belongs to the app. The depth cache's cap moved to Vergence with the cache
 (`VergencePolicy.depthCacheCap`). Set once at launch and read from any thread.

 A lock rather than an actor or `@MainActor`: `DepthCacheStore.enforceBudget`
 is called from the conversion queue and from Settings, neither of which can
 await. This mirrors `RAVEMetricCollector` in RAVEEngine, and for the same
 reason — making the read async would make it unusable from exactly the callers
 that need it.
 */

import Foundation
import os

/// Whether a player's sound turns with the head (`.fixed`, or unspatialized
/// for mono and stereo) or stays where the video is.
public enum RAVEHeadLockedSound: String, Sendable, CaseIterable {
    /// Sound stays anchored to the video: head-tracked 5.1/7.1, and stereo
    /// anchored to its window where the player names one.
    case off
    /// Every player's sound turns with the head.
    case always
    /// Decided per player by its audio, once it has been probed: mono and
    /// stereo play head-locked (unspatialized, so they keep full quality) and
    /// 5.1/7.1 stays head-tracked, where it gets its spatial features.
    case byLayout

    /// Whether sound with this layout plays head-locked. `multichannel` is
    /// true for 5.1/7.1 and up, false for mono or stereo and nil before the
    /// audio has been probed, which `.byLayout` reads as stereo: the safe
    /// guess, since it leaves the sound as the source mixed it.
    public func locks(multichannel: Bool?) -> Bool {
        switch self {
        case .off: false
        case .always: true
        case .byLayout: multichannel != true
        }
    }
}

public enum RAVEMediaPolicy {
    /// Allow system spatialization of stereo when a player has no explicit
    /// scene anchor. Custom-rendered window video supplies its owning scene and
    /// anchors stereo there regardless, so concurrent windows stay independent.
    /// Off by default for players without a scene ID; surround remains
    /// head-tracked (see RAVESpatialAudio.swift).
    public static var spatializeStereo: Bool {
        get { storage.withLock { $0.spatializeStereo } }
        set { storage.withLock { $0.spatializeStereo = newValue } }
    }

    /// Where sound sits relative to the head, for every player. Setting it
    /// re-applies to every player the policy has been applied to
    /// (`RAVESpatialAudio.swift`).
    public static var headLockedSound: RAVEHeadLockedSound {
        get { storage.withLock { $0.headLockedSound } }
        set {
            let changed = storage.withLock { storage in
                defer { storage.headLockedSound = newValue }
                return storage.headLockedSound != newValue
            }
            #if os(visionOS)
            if changed { RAVESpatialAudioPlayers.refreshSurroundAnchoring() }
            #endif
        }
    }

    /// Play genuine multichannel (5.1/7.1) locked to the head: the virtual
    /// speakers keep their layout around the listener and turn with them
    /// instead of staying anchored to a window. Shorthand for
    /// `headLockedSound` being `.always` (setting it false means `.off`).
    public static var headLockedSurround: Bool {
        get { headLockedSound == .always }
        set { headLockedSound = newValue ? .always : .off }
    }

    /// The listener's EQ, for the players RAVEMedia owns: the stereo engine attaches it to each
    /// item it creates (`AVPlayerItem.attachAudioEQ`). An app sets it once at launch and puts it
    /// on its own players the same way. Nil: no EQ.
    public static var audioEQ: RAVEAudioEQ? {
        get { storage.withLock { $0.audioEQ } }
        set { storage.withLock { $0.audioEQ = newValue } }
    }

    private struct Storage: Sendable {
        var spatializeStereo = false
        var headLockedSound = RAVEHeadLockedSound.off
        var audioEQ: RAVEAudioEQ?
    }

    private static let storage = OSAllocatedUnfairLock(initialState: Storage())
}
