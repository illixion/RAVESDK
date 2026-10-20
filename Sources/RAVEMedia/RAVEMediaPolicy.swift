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

public enum RAVEMediaPolicy {
    /// Leave visionOS's own spatialization alone, so plain stereo is
    /// spatialized and window-anchored too; `applySpatialAudioPolicy` then
    /// does nothing. Off by default: stereo plays non-spatialized and genuine
    /// multichannel stays head-tracked (see RAVESpatialAudio.swift for why).
    /// web-yt-dlp's player offered this as "Spatialize stereo audio", for a
    /// single-window viewer where the wrong-window anchoring can't happen.
    public static var spatializeStereo: Bool {
        get { storage.withLock { $0.spatializeStereo } }
        set { storage.withLock { $0.spatializeStereo = newValue } }
    }

    /// Play genuine multichannel (5.1/7.1) locked to the head: the virtual
    /// speakers keep their layout around the listener and turn with them
    /// instead of staying anchored to a window. Setting it re-applies to every
    /// player the policy has been applied to (`RAVESpatialAudio.swift`).
    public static var headLockedSurround: Bool {
        get { storage.withLock { $0.headLockedSurround } }
        set {
            let changed = storage.withLock { storage in
                defer { storage.headLockedSurround = newValue }
                return storage.headLockedSurround != newValue
            }
            #if os(visionOS)
            if changed { RAVESpatialAudioPlayers.refreshSurroundAnchoring() }
            #endif
        }
    }

    private struct Storage: Sendable {
        var spatializeStereo = false
        var headLockedSurround = false
    }

    private static let storage = OSAllocatedUnfairLock(initialState: Storage())
}
