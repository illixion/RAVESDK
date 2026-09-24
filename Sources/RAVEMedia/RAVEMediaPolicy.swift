/*
 RAVEMedia - host-supplied policy.

 Two things the depth pipeline needs but cannot decide for itself, because the
 answer belongs to the app: how much disk the depth cache may use, and where
 conversions may write. Both are set once at launch and read from whatever
 thread the cache happens to be running on.

 A lock rather than an actor or `@MainActor`: `DepthCacheStore.enforceBudget`
 is called from the conversion queue and from Settings, neither of which can
 await. This mirrors `RAVEMetricCollector` in RAVEEngine, and for the same
 reason — making the read async would make it unusable from exactly the callers
 that need it.
 */

import Foundation
import os

public enum RAVEMediaPolicy {
    /// Byte cap the depth cache must stay under, computed from its current
    /// total size. Spatial Stash routes this to `CacheBudget.cap(for: .depth,
    /// currentSize:)`, whose free-space guard can return a cap *below* the
    /// current size to force a trim — so implementations may, and should, do
    /// that rather than only ever growing.
    ///
    /// Unset means unbounded: entries are never evicted for size. That is the
    /// right default for a host with no cache-budget concept at all, and a
    /// deliberate one — silently evicting a user's expensive conversions
    /// because a host forgot to configure a cap would be worse than growing.
    public static var depthCacheCap: (@Sendable (_ currentSize: Int64) -> Int64)? {
        get { storage.withLock { $0.depthCacheCap } }
        set { storage.withLock { $0.depthCacheCap = newValue } }
    }

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

    private struct Storage: Sendable {
        var depthCacheCap: (@Sendable (Int64) -> Int64)?
        var spatializeStereo = false
    }

    private static let storage = OSAllocatedUnfairLock(initialState: Storage())
}
