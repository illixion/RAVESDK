import Foundation
import Testing
@testable import RAVEMedia

/// `Pseudo3DSettings.init(from:)` is hand-written and decodes JSON already on
/// users' devices — a global in UserDefaults and a per-window copy inside each
/// persisted `VideoWindowValue`. Two of its behaviours are load-bearing and
/// neither was covered: surviving missing keys, and normalising the retired
/// 0.45 convergence default.
@Suite("Pseudo3DSettings persistence")
struct Pseudo3DSettingsTests {
    private func decode(_ json: String) throws -> Pseudo3DSettings {
        try JSONDecoder().decode(Pseudo3DSettings.self, from: Data(json.utf8))
    }

    /// Synthesised `Codable` would throw on a missing key and reset every user
    /// to `.default`; `decodeIfPresent` is what keeps old blobs decoding as
    /// fields are added.
    @Test func missingKeysFallBackToDefaultsRatherThanThrowing() throws {
        #expect(try decode("{}") == .default)
        #expect(try decode(#"{"convergence": 0.8}"#).convergence == 0.8)
    }

    /// Retired keys need no handling — keyed decoding ignores JSON keys with no
    /// matching case. `autoConvergence` was one such key.
    @Test func retiredKeysAreIgnored() throws {
        let settings = try decode(#"{"convergence": 0.7, "autoConvergence": true}"#)
        #expect(settings.convergence == 0.7)
    }

    /// The renderer pins strength to the default, so a persisted user-tuned
    /// value must not survive decoding — otherwise `isModified` sees a
    /// difference that the warp never honours.
    @Test func legacyDepthStrengthIsDiscarded() throws {
        let settings = try decode(#"{"depthStrength": 0.03, "convergence": 1.0}"#)
        #expect(settings.depthStrength == Pseudo3DSettings.default.depthStrength)
        #expect(!settings.isModified)
    }

    /// The normalisation this test exists for. A persisted 0.45 was the *old*
    /// default, so leaving it alone does two bad things at once: the global
    /// keeps the old plane forever, and — because `isModified` compares against
    /// `.default` — a per-window 0.45 starts counting as modified and shadows
    /// the global.
    @Test func legacyConvergenceDefaultAdoptsTheCurrentDefault() throws {
        let settings = try decode(#"{"convergence": 0.45}"#)
        #expect(settings.convergence == Pseudo3DSettings.default.convergence)
        #expect(!settings.isModified)
    }

    /// Only the exact old default is rewritten. This is safe *because* the
    /// slider is continuous and unstepped, so 0.45 is only ever reachable as
    /// the old default — but a value merely near it is a real user choice.
    @Test(arguments: [0.44, 0.451, 0.46])
    func valuesNearTheLegacyDefaultAreLeftAlone(value: Double) throws {
        let settings = try decode(#"{"convergence": \#(value)}"#)
        #expect(settings.convergence == value)
        #expect(settings.isModified)
    }

    /// Round-trips: what the app writes today must decode back unchanged.
    @Test func encodedSettingsRoundTrip() throws {
        var settings = Pseudo3DSettings.default
        settings.convergence = 0.62
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Pseudo3DSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.isModified)
    }

    /// `.default` is the comparison `isModified` and the per-window-vs-global
    /// fallback are both written against.
    @Test func defaultIsNotModified() {
        #expect(!Pseudo3DSettings.default.isModified)
        #expect(Pseudo3DSettings() == Pseudo3DSettings.default)
    }
}
