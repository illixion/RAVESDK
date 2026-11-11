import Foundation
import Testing
import RAVEMedia
@testable import RAVEFilm

/// The listener's EQ on the film's object audio: every element is filtered where it renders, so
/// the same filter on each object is the EQ on the whole mix.
@Suite("Film equalizer")
struct FilmEqualizerTests {
    static let rate = FilmRoomReverbTests.rate

    private func tone(_ f: Int, _ ch: Int) -> Float {
        ch == 0 ? 0.2 * Float(sin(2 * Double.pi * 1_000 * Double(f) / Double(Self.rate))) : 0
    }

    @available(macOS 15.0, *)
    private func gainDB(_ audio: AtmosObjectAudio) -> Double {
        let out = FilmTimeStretchTests.render(audio, channel: 0, frames: Self.rate)
        let reference = (0 ..< Self.rate).map { tone($0, 0) }
        let from = Self.rate / 4
        func rms(_ x: ArraySlice<Float>) -> Double {
            (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
        }
        return 20 * log10(rms(out[from...]) / rms(reference[from...]))
    }

    @Test func anEnabledEqualizerShapesTheObjects() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, _) = ReverbFixture.makeAudio(fill: tone)
        audio.equalizer.update(EQSettings(enabled: true, preampDB: 0, autoPreamp: false,
                                          bands: [EQBandSetting(frequency: 1_000, gain: 6, q: 1.41)]))
        let gain = gainDB(audio)
        // Quantising to Int16 adds nothing audible at this level; the band's centre gain is +6 dB.
        #expect(abs(gain - 6) <= 0.3, "measured \(gain) dB")
    }

    @Test func aDisabledEqualizerLeavesTheSceneAsItIs() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, _) = ReverbFixture.makeAudio(fill: tone)
        var settings = EQSettings(enabled: false, preampDB: -6, autoPreamp: false,
                                  bands: [EQBandSetting(frequency: 1_000, gain: 12)])
        settings.enabled = false
        audio.equalizer.update(settings)
        #expect(abs(gainDB(audio)) <= 0.02)
    }

    @MainActor
    @Test func theListenersEQMovesTheFilmLive() throws {
        guard #available(macOS 15.0, *) else { return }
        let defaults = try #require(UserDefaults(suiteName: "FilmEqualizerTests-\(UUID().uuidString)"))
        let eq = RAVEAudioEQ(defaults: defaults)
        let (audio, _) = ReverbFixture.makeAudio(fill: tone)
        eq.follow(audio.equalizer)

        #expect(abs(gainDB(audio)) <= 0.02) // off to begin with

        eq.settings = EQSettings(enabled: true, preampDB: -6, autoPreamp: false, bands: [])
        audio.start(at: 0)
        #expect(abs(gainDB(audio) + 6) <= 0.3)

        eq.setEnabled(false)
        audio.start(at: 0)
        _ = FilmTimeStretchTests.render(audio, channel: 0, frames: Self.rate / 2) // the fade out
        audio.start(at: 0)
        #expect(abs(gainDB(audio)) <= 0.05)
    }

    @Test func theProcessorCoversEveryElementAndEveryReverbOutput() {
        guard #available(macOS 15.0, *) else { return }
        let (audio, scene) = ReverbFixture.makeAudio(fill: tone)
        #expect(audio.equalizer.channelCount == scene.elements.count + FilmRoomReverb.outputCount)
    }
}
