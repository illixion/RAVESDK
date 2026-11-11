/*
 RAVEMedia - the real-time half of the audio EQ.

 `EQSettings` is the model and the curve math; this is the DSP that plays it:
 a cascade of RBJ biquads per channel, built from the same
 `EQSettings.coefficients(for:sampleRate:)` the editor draws, so the curve on
 screen is the curve in the speakers (at the rate the audio actually runs at,
 which `configure(sampleRate:channelCount:)` takes from the host).

 Hosts: `EQAudioTap` (any file-backed `AVPlayerItem`), RAVEFilm's object audio
 (one channel per object, so the same filter on every channel is the EQ on the
 mix: the filter is linear). Anything else with a render callback can call
 `process(channel:…)` too.

 Threading
 - `update(_:)` and `configure(…)` are called off the audio thread (main actor
   in practice) and publish one immutable coefficient set.
 - `process(channel:…)` runs on the audio thread, one thread per channel (a
   channel's state is touched only by its own calls). It never allocates,
   never waits: it picks up a new coefficient set with a `try`-lock and, if
   the writer holds the lock at that instant, keeps the old set for one more
   buffer.
 - `configure` must not overlap `process` (a tap's `prepare` precedes the
   first `process`; a film builds its processor before its generators start).

 Clicks: enabling or disabling the EQ and every change of the preamp are
 ramped across one buffer, so neither steps the signal. Band changes keep the
 filter state (transposed direct form II holds up under live coefficient
 changes), which is what a slider drag does 60 times a second.

 State is `Double`: a 31 Hz shelf at 48 kHz has poles very near the unit
 circle, where `Float` direct-form filters turn audibly noisy.
 */

import Foundation
import os

public nonisolated final class EQProcessor: @unchecked Sendable {
    /// Doubles per band in a coefficient set: b0 b1 b2 a1 a2, all divided by a0.
    private static let stride = 5
    private static let maxBands = EQSettings.maxBands

    public private(set) var channelCount: Int
    public private(set) var sampleRate: Double

    /// What `update` publishes and `process` reads, always under `lock`.
    private final class Published: @unchecked Sendable {
        var generation = 0
        var bandCount = 0
        var coefficients = [Double](repeating: 0, count: EQProcessor.maxBands * EQProcessor.stride)
        /// Linear gain of the preamp (1 when the EQ is off).
        var preamp: Float = 1
        /// 1 when enabled, 0 when bypassed; the processor ramps to it.
        var wet: Float = 0
    }

    private let published = Published()
    /// A raw `os_unfair_lock`: the audio thread only ever `try`-locks it, and a closure-based
    /// lock would have to capture the per-channel pointers `process` works on.
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()
    /// The last settings handed to `update`, kept so a change of sample rate can rebuild the set.
    private let latest = OSAllocatedUnfairLock(initialState: EQSettings())

    // Per-channel state, in raw memory so the audio thread never touches ARC or the allocator.
    private var state: UnsafeMutablePointer<Double>          // channels × bands × 2 (z1, z2)
    private var coefficients: UnsafeMutablePointer<Double>   // channels × bands × stride
    private var seenGeneration: UnsafeMutablePointer<Int>    // channels
    private var activeBands: UnsafeMutablePointer<Int>       // channels
    private var targetPreamp: UnsafeMutablePointer<Float>    // channels
    private var targetWet: UnsafeMutablePointer<Float>       // channels
    private var currentPreamp: UnsafeMutablePointer<Float>   // channels
    private var currentWet: UnsafeMutablePointer<Float>      // channels

    public init(channelCount: Int = 2, sampleRate: Double = EQSettings.displaySampleRate) {
        let channels = max(1, channelCount)
        self.channelCount = channels
        self.sampleRate = sampleRate
        state = Self.allocate(channels * Self.maxBands * 2, 0)
        coefficients = Self.allocate(channels * Self.maxBands * Self.stride, 0)
        seenGeneration = Self.allocate(channels, -1)
        activeBands = Self.allocate(channels, 0)
        targetPreamp = Self.allocate(channels, Float(1))
        targetWet = Self.allocate(channels, Float(0))
        currentPreamp = Self.allocate(channels, Float(1))
        currentWet = Self.allocate(channels, Float(0))
    }

    deinit {
        lock.deallocate()
        state.deallocate(); coefficients.deallocate(); seenGeneration.deallocate()
        activeBands.deallocate(); targetPreamp.deallocate(); targetWet.deallocate()
        currentPreamp.deallocate(); currentWet.deallocate()
    }

    private static func allocate<T>(_ count: Int, _ value: T) -> UnsafeMutablePointer<T> {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        pointer.initialize(repeating: value, count: count)
        return pointer
    }

    // MARK: - Control (not the audio thread)

    /// Sets the format the audio runs at. Resets every channel's filter state, so call it from
    /// `prepare`, never mid-stream.
    public func configure(sampleRate: Double, channelCount newCount: Int) {
        let channels = max(1, newCount)
        if channels != channelCount {
            state.deallocate(); coefficients.deallocate(); seenGeneration.deallocate()
            activeBands.deallocate(); targetPreamp.deallocate(); targetWet.deallocate()
            currentPreamp.deallocate(); currentWet.deallocate()
            channelCount = channels
            state = Self.allocate(channels * Self.maxBands * 2, 0)
            coefficients = Self.allocate(channels * Self.maxBands * Self.stride, 0)
            seenGeneration = Self.allocate(channels, -1)
            activeBands = Self.allocate(channels, 0)
            targetPreamp = Self.allocate(channels, Float(1))
            targetWet = Self.allocate(channels, Float(0))
            currentPreamp = Self.allocate(channels, Float(1))
            currentWet = Self.allocate(channels, Float(0))
        } else {
            state.update(repeating: 0, count: channels * Self.maxBands * 2)
            seenGeneration.update(repeating: -1, count: channels)
        }
        self.sampleRate = sampleRate
        // Start the ramp from the state the settings call for, so a prepared tap doesn't fade in.
        let settings = latest.withLock { $0 }
        update(settings)
        let wet: Float = Self.isActive(settings) ? 1 : 0
        let preamp = Float(pow(10, settings.preampDB / 20))
        for c in 0 ..< channels { currentWet[c] = wet; currentPreamp[c] = wet == 1 ? preamp : 1 }
    }

    /// Publishes new settings. Safe from any thread except while `configure` runs.
    public func update(_ settings: EQSettings) {
        latest.withLock { $0 = settings }
        let rate = sampleRate
        // Bands stay published while the EQ is off: the fade to bypass is a crossfade from the
        // filtered signal to the dry one, which needs the filter running until `wet` reaches 0.
        let bands = settings.bands.prefix(Self.maxBands).filter { abs($0.gain) >= 0.005 }
        var set = [Double](repeating: 0, count: Self.maxBands * Self.stride)
        for (index, band) in bands.enumerated() {
            let c = EQSettings.coefficients(for: band, sampleRate: rate)
            let o = index * Self.stride
            set[o] = c.b0 / c.a0; set[o + 1] = c.b1 / c.a0; set[o + 2] = c.b2 / c.a0
            set[o + 3] = c.a1 / c.a0; set[o + 4] = c.a2 / c.a0
        }
        let preamp = Float(pow(10, min(0, settings.preampDB) / 20))
        let wet: Float = Self.isActive(settings) ? 1 : 0
        let count = bands.count
        os_unfair_lock_lock(lock)
        published.generation &+= 1
        published.bandCount = count
        published.coefficients = set
        published.preamp = preamp
        published.wet = wet
        os_unfair_lock_unlock(lock)
    }

    /// Enabled, and doing something: a flat EQ with no preamp is the same as bypass.
    private static func isActive(_ settings: EQSettings) -> Bool {
        settings.enabled && (!settings.bands.isEmpty || settings.preampDB != 0)
    }

    /// True when `process` would leave the audio untouched (and has finished fading out).
    public var isBypassed: Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return published.wet == 0
    }

    // MARK: - Audio thread

    /// Filters `count` samples of one channel in place. `stride` is the distance between this
    /// channel's samples (1 for a plane, the channel count for interleaved audio).
    public func process(channel: Int, samples: UnsafeMutablePointer<Float>, count: Int, stride sampleStride: Int = 1) {
        guard channel >= 0, channel < channelCount, count > 0 else { return }
        let c = channel
        refresh(channel: c)
        let wetTarget = targetWet[c]
        var wet = currentWet[c]
        // Bypassed and settled: the common case costs one comparison.
        if wetTarget == 0, wet == 0 { return }

        let bands = activeBands[c]
        let z = state + c * Self.maxBands * 2
        let k = coefficients + c * Self.maxBands * Self.stride
        let gainTarget = targetPreamp[c]
        var gain = currentPreamp[c]
        let wetStep = (wetTarget - wet) / Float(count)
        let gainStep = (gainTarget - gain) / Float(count)

        for i in 0 ..< count {
            let x = samples[i * sampleStride]
            var y = Double(x)
            var b = 0
            while b < bands {
                let o = b * Self.stride
                let out = k[o] * y + z[b * 2]
                z[b * 2] = k[o + 1] * y - k[o + 3] * out + z[b * 2 + 1]
                z[b * 2 + 1] = k[o + 2] * y - k[o + 4] * out
                y = out
                b += 1
            }
            let filtered = Float(y) * gain
            samples[i * sampleStride] = x + (filtered - x) * wet
            wet += wetStep
            gain += gainStep
        }
        currentWet[c] = wetTarget
        currentPreamp[c] = gainTarget

        // A blown filter (non-finite state) or a denormal tail is cleared once per buffer.
        var bad = false
        for j in 0 ..< bands * 2 {
            if !z[j].isFinite { bad = true; break }
            if abs(z[j]) < 1e-30 { z[j] = 0 }
        }
        if bad {
            for j in 0 ..< Self.maxBands * 2 { z[j] = 0 }
            for i in 0 ..< count where !samples[i * sampleStride].isFinite { samples[i * sampleStride] = 0 }
        }
    }

    /// Takes a newer coefficient set if the writer isn't holding the lock this instant.
    private func refresh(channel c: Int) {
        guard os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        guard published.generation != seenGeneration[c] else { return }
        seenGeneration[c] = published.generation
        activeBands[c] = published.bandCount
        targetPreamp[c] = published.preamp
        targetWet[c] = published.wet
        let destination = coefficients + c * Self.maxBands * Self.stride
        published.coefficients.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: published.bandCount * Self.stride)
        }
    }
}
