import Foundation
import Testing
@testable import RAVEMedia

/// The EQ model's math is what makes the editor honest: the on-screen
/// curve (RBJ biquad responses) must match what a host's real DSP boundary
/// plays, and the Q→bandwidth conversion is the classic spot to get
/// silently wrong. These pin down both, plus persistence round-trips and
/// the draw-stroke → bands fit. Ported from Longwave's original
/// `EQSettingsTests` when the model moved into this shared package.
@Suite("EQSettings math and persistence")
struct EQSettingsTests {

    // MARK: - Frequency response

    @Test func parametricPeakGainAtCenter() {
        let band = EQBandSetting(frequency: 1_000, gain: 12, q: 1.41)
        // At the center frequency a peaking filter hits its full gain.
        #expect(abs(EQSettings.bandResponseDB(band: band, hz: 1_000) - 12) <= 0.1)
    }

    @Test func parametricPeakFlatFarAway() {
        let band = EQBandSetting(frequency: 1_000, gain: 12, q: 1.41)
        #expect(abs(EQSettings.bandResponseDB(band: band, hz: 30)) <= 0.3)
        #expect(abs(EQSettings.bandResponseDB(band: band, hz: 18_000)) <= 0.5)
    }

    @Test func cutIsSymmetricToBoost() {
        let boost = EQBandSetting(frequency: 500, gain: 9, q: 2)
        let cut = EQBandSetting(frequency: 500, gain: -9, q: 2)
        for hz in [100.0, 300, 500, 900, 4_000] {
            let boostDB = EQSettings.bandResponseDB(band: boost, hz: hz)
            let cutDB = EQSettings.bandResponseDB(band: cut, hz: hz)
            #expect(abs(boostDB - (-cutDB)) <= 0.05, "asymmetric at \(hz) Hz")
        }
    }

    @Test func shelvesReachFullGainInStopband() {
        let low = EQBandSetting(type: .lowShelf, frequency: 100, gain: 6)
        #expect(abs(EQSettings.bandResponseDB(band: low, hz: 20) - 6) <= 0.5)
        #expect(abs(EQSettings.bandResponseDB(band: low, hz: 5_000)) <= 0.3)

        let high = EQBandSetting(type: .highShelf, frequency: 8_000, gain: -6)
        #expect(abs(EQSettings.bandResponseDB(band: high, hz: 19_000) - (-6)) <= 0.6)
        #expect(abs(EQSettings.bandResponseDB(band: high, hz: 200)) <= 0.3)
    }

    @Test func combinedResponseSumsBandsAndPreamp() {
        var settings = EQSettings()
        settings.preampDB = -3
        settings.bands = [
            EQBandSetting(frequency: 100, gain: 6, q: 1.41),
            EQBandSetting(frequency: 100, gain: 6, q: 1.41),
        ]
        // Cascaded identical biquads double the dB; preamp adds on top.
        #expect(abs(settings.responseDB(atHz: 100) - (-3 + 12)) <= 0.2)
    }

    // MARK: - Q → bandwidth (octaves)

    @Test func qToBandwidthKnownValues() {
        // bw = (2/ln2)·asinh(1/(2Q)); Q ≈ 1.414 → ~1 octave is the
        // canonical sanity point.
        #expect(abs(EQSettings.bandwidthOctaves(q: 1.414) - 1.0) <= 0.02)
        // Narrower Q → narrower bandwidth, monotonically.
        #expect(EQSettings.bandwidthOctaves(q: 10) < EQSettings.bandwidthOctaves(q: 1))
        #expect(abs(EQSettings.bandwidthOctaves(q: 0.667) - 2.0) <= 0.05)
    }

    // MARK: - Persistence

    @Test func saveLoadRoundTrip() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        var settings = EQSettings()
        settings.enabled = true
        settings.preampDB = -4.5
        settings.bands = [
            EQBandSetting(type: .lowShelf, frequency: 80, gain: 4, q: 0.71),
            EQBandSetting(frequency: 2_500, gain: -6, q: 3.2),
        ]
        settings.save(to: defaults)
        #expect(EQSettings.load(from: defaults) == settings)
    }

    @Test func decodingLegacyJSONDefaultsAutoPreampOn() throws {
        // Settings saved before the autoPreamp field existed must decode
        // with the flag on, not fail or reset the EQ.
        let legacy = Data(#"{"enabled":true,"preampDB":-3,"bands":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: legacy)
        #expect(decoded.autoPreamp)
        #expect(decoded.enabled)
        #expect(decoded.preampDB == -3)
    }

    @Test func autoPreampFlagRoundTrips() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        var settings = EQSettings()
        settings.autoPreamp = false
        settings.preampDB = -2
        settings.save(to: defaults)
        #expect(EQSettings.load(from: defaults) == settings)
    }

    @Test func loadReturnsDefaultsWhenAbsentOrCorrupt() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        #expect(EQSettings.load(from: defaults) == EQSettings())

        defaults.set(Data("not json".utf8), forKey: EQSettings.defaultsKey)
        #expect(EQSettings.load(from: defaults) == EQSettings())
    }

    // MARK: - Clamping

    @Test func clampedLimitsAllParameters() {
        let wild = EQBandSetting(frequency: 100_000, gain: 90, q: 500).clamped()
        #expect(wild.frequency == EQSettings.maxFrequency)
        #expect(wild.gain == EQSettings.gainRange)
        #expect(wild.q == 10)

        let tiny = EQBandSetting(frequency: 1, gain: -90, q: 0).clamped()
        #expect(tiny.frequency == EQSettings.minFrequency)
        #expect(tiny.gain == -EQSettings.gainRange)
        #expect(tiny.q == 0.1)
    }

    // MARK: - Draw-stroke fit

    @Test func fitFlatLineProducesNoBands() {
        let flat = stride(from: 20.0, through: 20_000, by: 500).map { (hz: $0, db: 0.0) }
        #expect(EQSettings.fit(drawnCurve: flat).isEmpty)
    }

    @Test func fitConstantBoostHitsEveryCenter() {
        let curve = (0..<200).map { i -> (hz: Double, db: Double) in
            let hz = 20 * pow(1_000, Double(i) / 199) // 20 Hz → 20 kHz, log-spaced
            return (hz, 6.0)
        }
        let bands = EQSettings.fit(drawnCurve: curve)
        #expect(bands.count == EQSettings.fitCenters.count)
        for band in bands {
            #expect(abs(band.gain - 6) <= 0.2, "at \(band.frequency) Hz")
        }
        // Edges become shelves so the curve holds past them.
        #expect(bands.first?.type == .lowShelf)
        #expect(bands.last?.type == .highShelf)
        #expect(bands.dropFirst().dropLast().allSatisfy { $0.type == .parametric })
    }

    @Test func fitTiltedLineIsMonotonic() {
        // Bass boost sloping down to treble cut.
        let curve = (0..<200).map { i -> (hz: Double, db: Double) in
            let t = Double(i) / 199
            return (hz: 20 * pow(1_000, t), db: 10 - 20 * t)
        }
        let bands = EQSettings.fit(drawnCurve: curve)
        let gains = bands.map(\.gain)
        #expect(gains == gains.sorted(by: >))
        #expect((gains.first ?? 0) > 5)
        #expect((gains.last ?? 0) < -5)
    }

    @Test func fitRespectsMaxBandsBudget() {
        #expect(EQSettings.fitCenters.count <= EQSettings.maxBands)
    }

    @Test func fitIgnoresGarbageInput() {
        #expect(EQSettings.fit(drawnCurve: []).isEmpty)
        #expect(EQSettings.fit(drawnCurve: [(hz: -5, db: .infinity)]).isEmpty)
    }

    // MARK: - Auto preamp

    @Test func autoTrimOffsetsPeakBoost() {
        var settings = EQSettings()
        settings.bands = [EQBandSetting(frequency: 100, gain: 8, q: 1.41)]
        settings.autoTrimPreamp()
        #expect(abs(settings.preampDB - (-8)) <= 0.2)
        // Peak of the full response (bands + preamp) never exceeds 0 dB.
        let peak = settings.responseCurve().map(\.db).max() ?? 0
        #expect(peak <= 0.1)
    }

    @Test func autoTrimAccountsForOverlappingBoosts() {
        var settings = EQSettings()
        // Two overlapping +6 dB bands sum to ~+12 at the shared center.
        settings.bands = [
            EQBandSetting(frequency: 1_000, gain: 6, q: 1.41),
            EQBandSetting(frequency: 1_000, gain: 6, q: 1.41),
        ]
        settings.autoTrimPreamp()
        #expect(abs(settings.preampDB - (-12)) <= 0.3)
    }

    @Test func autoTrimZeroForCutOnlyCurve() {
        var settings = EQSettings()
        settings.preampDB = -5 // stale trim from removed boosts
        settings.bands = [EQBandSetting(frequency: 300, gain: -9, q: 1)]
        settings.autoTrimPreamp()
        #expect(abs(settings.preampDB) <= 0.1)
    }

    @Test func autoTrimIsIdempotent() {
        var settings = EQSettings()
        settings.bands = [EQBandSetting(frequency: 4_000, gain: 10, q: 2)]
        settings.autoTrimPreamp()
        let once = settings.preampDB
        settings.autoTrimPreamp()
        #expect(abs(settings.preampDB - once) <= 0.001)
    }

    @Test func autoTrimClampsToFloor() {
        var settings = EQSettings()
        settings.bands = [
            EQBandSetting(frequency: 1_000, gain: 24, q: 1.41),
        ]
        settings.autoTrimPreamp()
        #expect(settings.preampDB == -12) // trim floor
    }

    // MARK: - Presets

    @Test func customPresetRoundTrip() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let presets = [
            EQPreset(name: "My Curve", bands: [
                EQBandSetting(type: .lowShelf, frequency: 90, gain: 3),
                EQBandSetting(frequency: 3_000, gain: -4, q: 2.5),
            ]),
        ]
        EQPreset.saveCustom(presets, to: defaults)
        #expect(EQPreset.loadCustom(from: defaults) == presets)
    }

    @Test func loadCustomPresetsEmptyWhenAbsent() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        #expect(EQPreset.loadCustom(from: defaults).isEmpty)
    }

    @Test func builtInPresetsAreWithinLimits() {
        for preset in EQPreset.builtIns {
            #expect(preset.bands.count <= EQSettings.maxBands)
            for band in preset.bands {
                #expect(band.clamped() == band, "\(preset.name) band out of range")
            }
        }
    }
}
