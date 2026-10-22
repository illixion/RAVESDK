/*
 Hypnos - film sound faster or slower than it was mixed, at its own pitch

 Every element renders on a callback of its own (see AtmosObjectAudio), and
 those callbacks must stay sample-locked, so the stretch can't be a
 stateful processor per channel. It is a function of the output frame that
 every channel evaluates the same way: WSOLA (waveform-similarity
 overlap-add) on the transport's output timeline.

 - Grain k covers output frames [kH, kH + 2H) under a Hann window, so two
   grains overlap at every frame and their windows sum to one.
 - Grain k reads the scene from s_k, within ±`search` of where the speed
   puts it (`nominal`): the offset whose waveform best continues what
   grain k−1 would have played next. Overlapping in phase is what makes it
   sound like the same voice, faster, rather than a warble.
 - The first channel to reach grain k picks s_k from a downmix of the scene
   (the LFE left out, so the bass doesn't decide where dialogue splices)
   and publishes it in a ring; every other channel reads it from there, so
   all of them splice at the same frames.
 - s_k stays within `search` of the nominal position, so the sound never
   strays further than that (12 ms) from the picture, however long it plays.

 Positions here are scene frames relative to the transport's start frame,
 and output frames since its anchor. At speed 1 none of this runs.
 */

import Accelerate
import Foundation
import Synchronization

// Synchronization.Atomic; the package floor stays at macOS 14.
@available(macOS 15.0, *)
final class FilmTimeStretch: @unchecked Sendable {
    /// Output frames from one grain to the next; a grain is twice as long.
    let hop: Int
    /// How far a grain may move from its nominal position, in frames.
    let search: Int
    /// Hann window over a grain (2 × `hop`); halves `hop` apart sum to one.
    let window: UnsafeMutablePointer<Float>

    /// The search runs on a box-filtered downmix this many times shorter,
    /// then refines at full rate around the winner.
    private static let decimation = 4
    /// Published grains: 512 of 30 ms is 15 s, far more than the channels
    /// ever stand apart.
    private static let ringSize = 512
    private let ring: UnsafeMutablePointer<Atomic<UInt64>>
    /// Bumped by `restart`, so grains chosen for another start or speed are
    /// never reused. Never 0, which is what an empty ring entry reads.
    private let generationCounter = Atomic<UInt64>(1)
    private let speedBits = Atomic<UInt64>(1.0.bitPattern)

    init(sampleRate: Double) {
        hop = max(64, Int((sampleRate * 0.03).rounded()))
        search = min(Self.maxSearch, Int((sampleRate * 0.012).rounded()))
        let length = 2 * hop
        window = .allocate(capacity: length)
        for i in 0 ..< length {
            window[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(length)))
        }
        ring = .allocate(capacity: Self.ringSize)
        for i in 0 ..< Self.ringSize { (ring + i).initialize(to: Atomic(0)) }
    }

    deinit {
        window.deallocate()
        ring.deinitialize(count: Self.ringSize)
        ring.deallocate()
    }

    /// Scene frames played per output frame.
    var speed: Double { Double(bitPattern: speedBits.load(ordering: .acquiring)) }
    var generation: UInt64 { generationCounter.load(ordering: .acquiring) }

    /// A new start: forget every grain and play at `speed` from here. Call
    /// while the channels render silence, as `AtmosObjectAudio.start` does.
    func restart(speed: Double) {
        speedBits.store(speed.bitPattern, ordering: .releasing)
        var next = (generationCounter.load(ordering: .relaxed) + 1) & Self.generationMask
        if next == 0 { next = 1 }
        generationCounter.store(next, ordering: .releasing)
    }

    /// Where speed alone puts grain k's first frame: its centre then lands
    /// where the output's does.
    @inline(__always)
    func nominal(_ grain: Int, speed: Double) -> Int {
        Int((Double(grain + 1) * Double(hop) * speed).rounded()) - hop
    }

    /// The two grains under one output frame, cached across a buffer.
    struct Cursor {
        var grain = Int.min
        var current = 0
        var previous = 0
    }

    /// The scene frames output frame `output` plays, with their weights
    /// (summing to one). `downmix(from, count, into)` fills `count` frames
    /// of the reference signal from relative scene frame `from` (silence
    /// outside the scene), and is called only when a grain is chosen.
    @inline(__always)
    func taps(output: Int, cursor: inout Cursor, generation: UInt64, speed: Double,
              downmix: (Int, Int, UnsafeMutablePointer<Float>) -> Void) -> (a: Int, wa: Float, b: Int, wb: Float) {
        let grain = output / hop
        let offset = output - grain * hop
        if grain != cursor.grain {
            if grain == cursor.grain + 1 {
                cursor.previous = cursor.current
            } else {
                cursor.previous = start(of: grain - 1, generation: generation, speed: speed, downmix: downmix)
            }
            cursor.current = start(of: grain, generation: generation, speed: speed, downmix: downmix)
            cursor.grain = grain
        }
        return (cursor.current + offset, window[offset], cursor.previous + offset + hop, window[offset + hop])
    }

    /// Grain `grain`'s first scene frame: published, or chosen and published.
    func start(of grain: Int, generation: UInt64, speed: Double,
               downmix: (Int, Int, UnsafeMutablePointer<Float>) -> Void) -> Int {
        // Grain −1 ends where the scene starts: its second half reads frames
        // 0 ..< hop, which is what the output's first hop plays.
        guard grain >= 0 else { return -hop }
        let nominal = nominal(grain, speed: speed)
        let seen = ring[grain & (Self.ringSize - 1)].load(ordering: .acquiring)
        if let delta = Self.delta(seen, generation: generation, grain: grain) { return nominal + delta }

        // The grain before, as published; one nobody chose (the first after
        // a re-anchor) is taken at its nominal place rather than chosen here,
        // which after a jump would mean choosing every grain since the start.
        let previous: Int
        if grain == 0 {
            previous = -hop
        } else {
            let before = ring[(grain - 1) & (Self.ringSize - 1)].load(ordering: .acquiring)
            previous = self.nominal(grain - 1, speed: speed)
                + (Self.delta(before, generation: generation, grain: grain - 1) ?? 0)
        }
        let delta = bestDelta(continuing: previous, nominal: nominal, downmix: downmix)
        let (exchanged, original) = ring[grain & (Self.ringSize - 1)].compareExchange(
            expected: seen, desired: Self.pack(generation: generation, grain: grain, delta: delta),
            ordering: .acquiringAndReleasing
        )
        // Another channel published first: play its choice, as every other channel will.
        if !exchanged, let theirs = Self.delta(original, generation: generation, grain: grain) { return nominal + theirs }
        return nominal + delta
    }

    /// The offset from `nominal`, within ±`search`, whose next `hop` frames
    /// best match the `hop` frames after `previous + hop`: normalized
    /// cross-correlation, coarse on a decimated downmix, then exact.
    func bestDelta(continuing previous: Int, nominal: Int,
                   downmix: (Int, Int, UnsafeMutablePointer<Float>) -> Void) -> Int {
        let span = 2 * search + hop
        return withUnsafeTemporaryAllocation(of: Float.self, capacity: hop + span) { buffer -> Int in
            let target = buffer.baseAddress!
            let region = target + hop
            downmix(previous + hop, hop, target)
            downmix(nominal - search, span, region)
            var targetEnergy: Float = 0
            vDSP_svesq(target, 1, &targetEnergy, vDSP_Length(hop))
            // Silence: nothing to line up, so keep the nominal grid.
            guard targetEnergy > 1e-7 * Float(hop) else { return 0 }

            let d = Self.decimation
            let targetCount = hop / d
            let regionCount = span / d
            let coarse = withUnsafeTemporaryAllocation(of: Float.self, capacity: targetCount + regionCount) { decimated -> Int in
                let t = decimated.baseAddress!
                let r = t + targetCount
                Self.decimate(target, into: t, count: targetCount, by: d)
                Self.decimate(region, into: r, count: regionCount, by: d)
                let candidates = regionCount - targetCount + 1
                var energy: Float = 0
                vDSP_svesq(r, 1, &energy, vDSP_Length(targetCount))
                var best = search / d
                var bestScore = -Float.infinity
                for c in 0 ..< candidates {
                    var correlation: Float = 0
                    vDSP_dotpr(t, 1, r + c, 1, &correlation, vDSP_Length(targetCount))
                    let score = correlation / (energy + 1e-9).squareRoot()
                    if score > bestScore {
                        bestScore = score
                        best = c
                    }
                    if c + targetCount < regionCount {
                        energy += r[c + targetCount] * r[c + targetCount] - r[c] * r[c]
                    }
                }
                return best * d
            }

            var best = coarse
            var bestScore = -Float.infinity
            for c in max(0, coarse - d) ... min(2 * search, coarse + d) {
                var correlation: Float = 0
                var energy: Float = 0
                vDSP_dotpr(target, 1, region + c, 1, &correlation, vDSP_Length(hop))
                vDSP_svesq(region + c, 1, &energy, vDSP_Length(hop))
                let score = correlation / (energy + 1e-9).squareRoot()
                if score > bestScore {
                    bestScore = score
                    best = c
                }
            }
            return best - search
        }
    }

    private static func decimate(_ source: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>, count: Int, by d: Int) {
        let scale = 1 / Float(d)
        for i in 0 ..< count {
            var sum: Float = 0
            for j in 0 ..< d { sum += source[i * d + j] }
            out[i] = sum * scale
        }
    }

    // MARK: Ring entries

    // generation (16 bits) | grain (36 bits) | delta + 2048 (12 bits)
    private static let generationMask: UInt64 = 0xFFFF
    private static let grainMask: UInt64 = (1 << 36) - 1
    private static let deltaBias = 2048
    static let maxSearch = 2000

    private static func pack(generation: UInt64, grain: Int, delta: Int) -> UInt64 {
        (generation & generationMask) << 48
            | (UInt64(grain) & grainMask) << 12
            | UInt64(delta + deltaBias) & 0xFFF
    }

    @inline(__always)
    private static func delta(_ entry: UInt64, generation: UInt64, grain: Int) -> Int? {
        guard entry >> 48 == generation & generationMask, (entry >> 12) & grainMask == UInt64(grain) & grainMask else { return nil }
        return Int(entry & 0xFFF) - deltaBias
    }
}
