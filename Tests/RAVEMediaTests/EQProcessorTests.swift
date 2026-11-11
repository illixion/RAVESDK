import Foundation
import Testing
@testable import RAVEMedia

/// `EQProcessor` is what turns the editor's curve into sound, so these measure its
/// output on sine waves rather than trusting its coefficients: the gain it actually
/// applies has to match the analytic response of the same biquads at the rate the
/// audio runs at, and the on/off and preamp changes must not step the signal.
@Suite("EQProcessor")
struct EQProcessorTests {

    // MARK: - Helpers

    /// Runs a sine of `hz` through `processor` in `chunk`-sample buffers and returns the gain it
    /// applied, in dB, measured on the last 3/4 of a second (after the filter has settled).
    private func measuredGainDB(_ processor: EQProcessor, hz: Double, rate: Double, channel: Int = 0, chunk: Int = 512) -> Double {
        let total = Int(rate)
        var input = (0 ..< total).map { Float(0.25 * sin(2 * Double.pi * hz * Double($0) / rate)) }
        let reference = input
        var offset = 0
        while offset < total {
            let n = min(chunk, total - offset)
            input.withUnsafeMutableBufferPointer { buffer in
                processor.process(channel: channel, samples: buffer.baseAddress! + offset, count: n)
            }
            offset += n
        }
        let from = total / 4
        func rms(_ x: [Float]) -> Double {
            sqrt(x[from...].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(total - from))
        }
        return 20 * log10(rms(input) / rms(reference))
    }

    /// The analytic response of a settings' bands at `hz`, at an arbitrary rate (the model's own
    /// `responseDB` is fixed to the 48 kHz display rate).
    private func analyticDB(_ settings: EQSettings, hz: Double, rate: Double) -> Double {
        var total = settings.preampDB
        for band in settings.bands {
            let c = EQSettings.coefficients(for: band, sampleRate: rate)
            let w = 2 * Double.pi * hz / rate
            func mag2(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
                let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
                let im = -(c1 * sin(w) + c2 * sin(2 * w))
                return re * re + im * im
            }
            total += 10 * log10(mag2(c.b0, c.b1, c.b2) / mag2(c.a0, c.a1, c.a2))
        }
        return total
    }

    private func enabled(_ bands: [EQBandSetting], preamp: Double = 0) -> EQSettings {
        EQSettings(enabled: true, preampDB: preamp, autoPreamp: false, bands: bands)
    }

    private func make(_ settings: EQSettings, rate: Double, channels: Int = 1) -> EQProcessor {
        let processor = EQProcessor(channelCount: channels, sampleRate: rate)
        processor.update(settings)
        // `configure` starts the ramps settled on the settings, so the first buffer isn't a fade-in.
        processor.configure(sampleRate: rate, channelCount: channels)
        return processor
    }

    // MARK: - Gain matches the curve

    @Test(arguments: [48_000.0, 44_100.0, 32_000.0])
    func gainMatchesAnalyticResponse(rate: Double) {
        let settings = enabled([
            EQBandSetting(type: .lowShelf, frequency: 120, gain: 6),
            EQBandSetting(frequency: 1_000, gain: -9, q: 2),
            EQBandSetting(type: .highShelf, frequency: 8_000, gain: 4),
        ])
        let processor = make(settings, rate: rate)
        for hz in [60.0, 200, 700, 1_000, 1_800, 6_000, 12_000] {
            let measured = measuredGainDB(processor, hz: hz, rate: rate)
            let expected = analyticDB(settings, hz: hz, rate: rate)
            #expect(abs(measured - expected) <= 0.2, "\(hz) Hz at \(rate): measured \(measured), expected \(expected)")
        }
    }

    @Test func peakBandHitsItsGainAtItsCentreOn44k() {
        // 44.1 kHz material through coefficients built for 48 kHz would land every band 8.8% high.
        let processor = make(enabled([EQBandSetting(frequency: 1_000, gain: 12, q: 1.41)]), rate: 44_100)
        #expect(abs(measuredGainDB(processor, hz: 1_000, rate: 44_100) - 12) <= 0.2)
    }

    @Test func preampAloneAttenuates() {
        let processor = make(enabled([], preamp: -6), rate: 48_000)
        #expect(abs(measuredGainDB(processor, hz: 1_000, rate: 48_000) + 6) <= 0.05)
    }

    // MARK: - Bypass and ramps

    @Test func disabledIsBitExactBypass() {
        var settings = enabled([EQBandSetting(frequency: 1_000, gain: 12)])
        settings.enabled = false
        let processor = make(settings, rate: 48_000)
        var samples = (0 ..< 1_024).map { Float(sin(Double($0) * 0.1)) }
        let before = samples
        samples.withUnsafeMutableBufferPointer { processor.process(channel: 0, samples: $0.baseAddress!, count: 1_024) }
        #expect(samples == before)
        #expect(processor.isBypassed)
    }

    @Test func enablingFadesInInsteadOfStepping() {
        let processor = make(EQSettings(), rate: 48_000)
        // A loud 1 kHz tone, so a +12 dB boost would step the signal if it switched on at once.
        func buffer() -> [Float] { (0 ..< 4_800).map { Float(0.2 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) } }
        var first = buffer()
        first.withUnsafeMutableBufferPointer { processor.process(channel: 0, samples: $0.baseAddress!, count: 4_800) }
        processor.update(enabled([EQBandSetting(frequency: 1_000, gain: 12)]))
        var second = buffer()
        second.withUnsafeMutableBufferPointer { processor.process(channel: 0, samples: $0.baseAddress!, count: 4_800) }
        // The first processed sample is still the dry one (the ramp starts at wet = 0)…
        #expect(abs(second[0] - buffer()[0]) <= 1e-6)
        // …and no sample-to-sample jump is larger than the dry tone's own plus the boost's slope.
        let maxStep = zip(second, second.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(maxStep < 0.2 * 4 * 2 * Float.pi * 1_000 / 48_000 * 1.2)
        // Settled, it is the boosted tone.
        var third = buffer()
        third.withUnsafeMutableBufferPointer { processor.process(channel: 0, samples: $0.baseAddress!, count: 4_800) }
        let peak = third[2_400...].map { abs($0) }.max() ?? 0
        #expect(peak > 0.2 * 3.5 && peak < 0.2 * 4.5) // +12 dB ≈ ×3.98
    }

    // MARK: - Layout and robustness

    @Test func interleavedMatchesPlanar() {
        let settings = enabled([EQBandSetting(frequency: 500, gain: 8, q: 1)])
        let planar = make(settings, rate: 48_000, channels: 2)
        let interleaved = make(settings, rate: 48_000, channels: 2)
        let left = (0 ..< 2_048).map { Float(0.3 * sin(Double($0) * 0.07)) }
        let right = (0 ..< 2_048).map { Float(0.3 * sin(Double($0) * 0.19)) }
        var l = left, r = right
        l.withUnsafeMutableBufferPointer { planar.process(channel: 0, samples: $0.baseAddress!, count: 2_048) }
        r.withUnsafeMutableBufferPointer { planar.process(channel: 1, samples: $0.baseAddress!, count: 2_048) }
        var mixed = zip(left, right).flatMap { [$0, $1] }
        mixed.withUnsafeMutableBufferPointer {
            interleaved.process(channel: 0, samples: $0.baseAddress!, count: 2_048, stride: 2)
            interleaved.process(channel: 1, samples: $0.baseAddress! + 1, count: 2_048, stride: 2)
        }
        for i in 0 ..< 2_048 {
            #expect(mixed[i * 2] == l[i])
            #expect(mixed[i * 2 + 1] == r[i])
        }
    }

    @Test func channelsDoNotShareFilterState() {
        let processor = make(enabled([EQBandSetting(frequency: 1_000, gain: 12)]), rate: 48_000, channels: 2)
        var loud = (0 ..< 4_800).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        loud.withUnsafeMutableBufferPointer { processor.process(channel: 0, samples: $0.baseAddress!, count: 4_800) }
        var silence = [Float](repeating: 0, count: 512)
        silence.withUnsafeMutableBufferPointer { processor.process(channel: 1, samples: $0.baseAddress!, count: 512) }
        #expect(silence.allSatisfy { $0 == 0 })
    }

    @Test func recoversFromNonFiniteInput() {
        let processor = make(enabled([EQBandSetting(frequency: 1_000, gain: 12)]), rate: 48_000)
        var poisoned = [Float](repeating: 0.1, count: 256)
        poisoned[10] = .nan
        poisoned.withUnsafeMutableBufferPointer { processor.process(channel: 0, samples: $0.baseAddress!, count: 256) }
        #expect(poisoned.allSatisfy { $0.isFinite })
        var next = [Float](repeating: 0.1, count: 256)
        next.withUnsafeMutableBufferPointer { processor.process(channel: 0, samples: $0.baseAddress!, count: 256) }
        #expect(next.allSatisfy { $0.isFinite })
    }

    @Test func liveUpdateWhileProcessingStaysFinite() {
        // A slider drag publishes a new set many times a second between buffers.
        let processor = make(enabled([EQBandSetting(frequency: 1_000, gain: 3)]), rate: 48_000)
        var phase = 0.0
        for step in 0 ..< 200 {
            processor.update(enabled([EQBandSetting(frequency: 200 + Double(step) * 80, gain: Double(step % 24) - 12, q: 0.5 + Double(step % 7))]))
            var buffer = (0 ..< 480).map { _ -> Float in phase += 0.05; return Float(0.3 * sin(phase)) }
            buffer.withUnsafeMutableBufferPointer { processor.process(channel: 0, samples: $0.baseAddress!, count: 480) }
            #expect(buffer.allSatisfy { $0.isFinite && abs($0) < 4 })
        }
    }
}
