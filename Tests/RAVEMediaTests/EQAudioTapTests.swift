import AVFoundation
import Foundation
import Testing
@testable import RAVEMedia

/// The tap, end to end and offline: a real audio file read through the audio mix that
/// `RAVEAudioEQ` builds, which is the same mix `attach(to:)` puts on a player item, with
/// `AVAssetReaderAudioMixOutput` running the tap the way playback does.
@MainActor
@Suite("EQAudioTap")
struct EQAudioTapTests {

    /// A mono 16-bit WAV of a sine, written to a unique temp file.
    private func writeTone(hz: Double, rate: Double, seconds: Double = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eqtap-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.int16ChannelData![0]
        for i in 0 ..< Int(frames) { data[i] = Int16(0.25 * 32767 * sin(2 * Double.pi * hz * Double(i) / rate)) }
        try file.write(from: buffer)
        return url
    }

    /// RMS of the file's audio (Float32 mono) read through `mix`, skipping the first half second.
    private func rms(of asset: AVAsset, through mix: AVAudioMix?) async throws -> Double {
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1,
        ])
        output.audioMix = mix
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        let skip = samples.count / 4
        let body = samples[skip...]
        return sqrt(body.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(body.count))
    }

    private func suite() -> UserDefaults {
        let name = "EQAudioTapTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test(arguments: [48_000.0, 44_100.0])
    func tapBoostsTheFileByTheBandsGain(rate: Double) async throws {
        let url = try writeTone(hz: 1_000, rate: rate)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)

        let eq = RAVEAudioEQ(defaults: suite(), saveDelay: .zero)
        eq.settings = EQSettings(enabled: true, preampDB: 0, autoPreamp: false,
                                 bands: [EQBandSetting(frequency: 1_000, gain: 9, q: 1.41)])
        let (mix, result) = await eq.audioMix(for: asset)
        #expect(result == .attached)

        let dry = try await rms(of: asset, through: nil)
        let wet = try await rms(of: asset, through: mix)
        let gain = 20 * log10(wet / dry)
        #expect(abs(gain - 9) <= 0.3, "measured \(gain) dB at \(rate) Hz")
    }

    @Test func tapFollowsSettingsChangedAfterItIsAttached() async throws {
        let url = try writeTone(hz: 1_000, rate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)

        let eq = RAVEAudioEQ(defaults: suite(), saveDelay: .zero)
        let (mix, _) = await eq.audioMix(for: asset)
        let off = try await rms(of: asset, through: mix) // disabled: untouched
        let dry = try await rms(of: asset, through: nil)
        #expect(abs(20 * log10(off / dry)) <= 0.01)

        eq.settings = EQSettings(enabled: true, preampDB: -6, autoPreamp: false, bands: [])
        let quieter = try await rms(of: asset, through: mix)
        #expect(abs(20 * log10(quieter / dry) + 6) <= 0.3)
    }

    @Test func assetWithoutAnAudioTrackIsReportedNotTapped() async {
        let eq = RAVEAudioEQ(defaults: suite(), saveDelay: .zero)
        let (mix, result) = await eq.audioMix(for: AVMutableComposition())
        #expect(mix == nil)
        #expect(result == .noAudioTrack)
    }

    @Test func settingsAndPresetsPersistInTheGivenDefaults() {
        let defaults = suite()
        let eq = RAVEAudioEQ(defaults: defaults, saveDelay: .zero)
        eq.apply(EQPreset.builtIns.first { $0.name == "Bass Boost" }!)
        #expect(eq.settings.enabled)
        #expect(eq.matchingPresetName == "Bass Boost")
        #expect(eq.settings.preampDB < 0) // auto-trimmed for the boost

        let reloaded = RAVEAudioEQ(defaults: defaults, saveDelay: .zero)
        #expect(reloaded.settings == eq.settings)
    }
}

@MainActor
@Suite("RAVEAudioEQ auto preamp")
struct RAVEAudioEQPreampTests {
    private func suite() -> UserDefaults {
        let name = "RAVEAudioEQPreampTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aBandEditRetrimsThePreampWhileAutoIsOn() {
        let eq = RAVEAudioEQ(defaults: suite(), saveDelay: .zero)
        eq.settings.bands = [EQBandSetting(frequency: 1_000, gain: 6)]
        #expect(eq.settings.preampDB < -5 && eq.settings.preampDB > -7)
        eq.settings.bands[0].gain = 3
        #expect(eq.settings.preampDB < -2 && eq.settings.preampDB > -4)
    }

    @Test func aManualPreampIsLeftAlone() {
        let eq = RAVEAudioEQ(defaults: suite(), saveDelay: .zero)
        eq.settings.autoPreamp = false
        eq.settings.preampDB = -2
        eq.settings.bands = [EQBandSetting(frequency: 1_000, gain: 9)]
        #expect(eq.settings.preampDB == -2)
    }
}

@MainActor
@Suite("RAVEAudioEQ saving")
struct RAVEAudioEQSaveTests {
    private func suite() -> UserDefaults {
        let name = "RAVEAudioEQSaveTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aDragWritesOnceAfterItEnds() async throws {
        let defaults = suite()
        let eq = RAVEAudioEQ(defaults: defaults, saveDelay: .milliseconds(150))
        eq.settings.bands = [EQBandSetting(frequency: 1_000, gain: 1)]
        for gain in 2 ... 8 { eq.settings.bands[0].gain = Double(gain) } // a drag: many changes
        #expect(defaults.data(forKey: EQSettings.defaultsKey) == nil, "written during the drag")
        try await Task.sleep(for: .milliseconds(500))
        let saved = EQSettings.load(from: defaults)
        #expect(saved.bands.first?.gain == 8)
    }

    @Test func saveNowWritesAtOnce() {
        let defaults = suite()
        let eq = RAVEAudioEQ(defaults: defaults, saveDelay: .seconds(60))
        eq.settings.enabled = true
        #expect(defaults.data(forKey: EQSettings.defaultsKey) == nil)
        eq.saveNow()
        #expect(EQSettings.load(from: defaults).enabled)
    }
}
