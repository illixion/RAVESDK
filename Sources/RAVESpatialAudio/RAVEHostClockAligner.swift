/*
 RAVESDK - keeping several render callbacks on one host-clock timeline

 A multichannel signal played as one mono source per channel (PHASE pull
 streams, RealityKit audio generators) is rendered by callbacks that each
 run on their **own** sample timeline. Measured on visionOS 27 (RealityKit,
 14 generators, origins 50 ms apart) and tvOS 27 (PHASE): sample times
 cannot be compared between channels, so a channel that reads "its" sample
 time from a shared buffer plays a different instant from its neighbour,
 and channels of one mix a few ms apart comb-filter.

 The host clock is the shared reference. The caller converts a render's
 host time to a frame of its own timeline (`timelineFrame`, against an
 anchor it chooses: "timeline frame F plays at host time H"). On a
 channel's first render this stores the offset from that frame to the
 channel's own sample time, and from then on the channel reads at
 `sampleTime + offset`, sample-continuous.

 Unless the renderer stalls: a stream whose sample time stops while host
 time runs on falls behind by the stall and, sample-continuous, stays
 there. PHASE on tvOS did this right after start (about 1.7 s, measured
 2026-09-27, Apple TV over AirPlay). So a channel whose played frame strays
 more than `reanchorFrames` from the host-derived frame re-anchors to it:
 it skips the gap, and every channel lands on the same host-derived frame.

 What it costs: nothing in buffering. A channel plays exactly the frame the
 host clock says is due; the threshold only bounds how far one may drift
 before it is pulled back (50 ms by default, well past buffer-to-buffer
 jitter of the timestamps, well inside what reads as out of sync).

 Hoisted from RAVEFilm's `AtmosObjectAudio` (2026-10-04) when Longwave's
 Moonlight surround became the second consumer. It knows nothing about
 what is played; the caller owns the anchor and the samples.

 Threading: each channel's state is written only by that channel's render
 thread. `invalidate()` may be called from any thread; channels re-derive
 their offset on their next render.
 */

import Foundation
import Synchronization

// Synchronization.Atomic; the package floor stays at macOS 14.
@available(macOS 15.0, *)
public final class RAVEHostClockAligner: @unchecked Sendable {
    public let channelCount: Int
    /// Host ticks (mach absolute time) → timeline frames.
    public let framesPerTick: Double
    /// Drift that forces a re-anchor.
    public let reanchorFrames: Int64

    /// Timeline frame minus own sample time; `.min` = not yet derived.
    private let offset: UnsafeMutablePointer<Int64>
    /// The epoch each channel's offset was derived under.
    private let derivedEpoch: UnsafeMutablePointer<Int>
    private let drift: UnsafeMutablePointer<Int64>
    private let fallbackCursor: UnsafeMutablePointer<Int64>
    private let epochCounter = Atomic<Int>(0)
    private let reanchorCounter = Atomic<Int>(0)

    /// - Parameters:
    ///   - framesPerTick: host ticks → frames; nil reads the mach timebase.
    ///     Tests pass their own.
    public init(channelCount: Int, sampleRate: Double, reanchorSeconds: Double = 0.05,
                framesPerTick: Double? = nil) {
        self.channelCount = channelCount
        self.framesPerTick = framesPerTick ?? Self.hostFramesPerTick(sampleRate: sampleRate)
        reanchorFrames = Int64(sampleRate * reanchorSeconds)
        offset = .allocate(capacity: channelCount)
        offset.initialize(repeating: .min, count: channelCount)
        derivedEpoch = .allocate(capacity: channelCount)
        derivedEpoch.initialize(repeating: -1, count: channelCount)
        drift = .allocate(capacity: channelCount)
        drift.initialize(repeating: 0, count: channelCount)
        fallbackCursor = .allocate(capacity: channelCount)
        fallbackCursor.initialize(repeating: 0, count: channelCount)
    }

    deinit {
        offset.deallocate()
        derivedEpoch.deallocate()
        drift.deallocate()
        fallbackCursor.deallocate()
    }

    /// Mach host ticks → frames at `sampleRate`.
    public static func hostFramesPerTick(sampleRate: Double) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9 * sampleRate
    }

    /// The timeline frame due at `hostTime`, given that `anchorFrame` plays
    /// at `anchorHostTime`. Signed: a render can be stamped before the anchor.
    @inline(__always)
    public func timelineFrame(hostTime: UInt64, anchorFrame: Int64, anchorHostTime: UInt64) -> Int64 {
        anchorFrame + Int64((Double(hostTime) - Double(anchorHostTime)) * framesPerTick)
    }

    /// Bumped by `invalidate()`; a caller that reads its anchor under a lock
    /// should read this under the same lock and pass it to `frame`.
    public var epoch: Int { epochCounter.load(ordering: .acquiring) }

    /// Every channel re-derives its offset on its next render (a new anchor,
    /// a restart). Safe from any thread.
    public func invalidate() {
        epochCounter.add(1, ordering: .releasing)
    }

    /// Forgets offsets and drift telemetry and restarts the fallback cursor
    /// at `fallbackFrame`. The per-channel fields are written racily, so call
    /// it while channels render silence (a stopped transport), as a restart
    /// does.
    public func reset(fallbackFrame: Int64 = 0) {
        for ch in 0 ..< channelCount {
            offset[ch] = .min
            drift[ch] = 0
            fallbackCursor[ch] = fallbackFrame
        }
        invalidate()
    }

    /// The timeline frame channel `ch` plays this render. Call from that
    /// channel's render thread only.
    @inline(__always)
    public func frame(channel ch: Int, sampleTime: Int64, timelineFrame due: Int64, epoch: Int? = nil) -> Int64 {
        let current = epoch ?? self.epoch
        if offset[ch] == .min || derivedEpoch[ch] != current {
            offset[ch] = due - sampleTime
            derivedEpoch[ch] = current
        }
        var played = sampleTime + offset[ch]
        let distance = abs(due - played)
        drift[ch] = max(drift[ch], distance)
        if distance > reanchorFrames {
            offset[ch] = due - sampleTime
            played = due
            reanchorCounter.add(1, ordering: .relaxed)
        }
        return played
    }

    /// For a render without valid timestamps: continues the channel's own
    /// cursor from the last `reset(fallbackFrame:)`.
    @inline(__always)
    public func fallbackFrame(channel ch: Int, count: Int) -> Int64 {
        let frame = fallbackCursor[ch]
        fallbackCursor[ch] += Int64(count)
        return frame
    }

    /// Largest |host-derived − played| frame distance channel `ch` has seen.
    public func maxDrift(channel ch: Int) -> Int64 { drift[ch] }

    public var maxDrift: Int64 { (0 ..< channelCount).map { drift[$0] }.max() ?? 0 }

    /// Re-anchors since creation (a stall or a jump in host time).
    public var reanchors: Int { reanchorCounter.load(ordering: .relaxed) }
}
