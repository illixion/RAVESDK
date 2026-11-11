import AVFoundation
import Foundation
import Testing
@testable import RAVEMedia

/// The stream path (`EQStreamPlayback`): what an HLS item gets in place of a tap. The engine's
/// sample buffers are checked for the EQ and the layout; then a real `AVPlayer` playing a file
/// drives the clock (the engine doesn't care whether the item is HLS, only the attach does), with
/// a synthetic reader standing in for the host's, and the renderer must follow it through play,
/// pause, a seek and the EQ going off. The player and renderer play at volume 0.
@MainActor
@Suite("EQStreamPlayback", .serialized)
struct EQStreamPlaybackTests {

    private func suite() -> UserDefaults {
        let name = "EQStreamPlaybackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func boosted() -> EQSettings {
        EQSettings(enabled: true, preampDB: 0, autoPreamp: false, bands: [EQBandSetting(frequency: 1_000, gain: 9, q: 1)])
    }

    /// Planar stereo float, a tone in each channel.
    private func tone(frames: Int, rate: Double, hz: Double = 1_000, amplitude: Float = 0.2, from start: Int = 0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< 2 {
            let plane = buffer.floatChannelData![c]
            for i in 0 ..< frames { plane[i] = amplitude * Float(sin(2 * Double.pi * hz * Double(start + i) / rate)) }
        }
        return buffer
    }

    // MARK: - Sample buffers

    @Test func sampleBuffersCarryTheEQInterleaved() throws {
        let rate = 48_000.0
        let processor = EQProcessor(channelCount: 2, sampleRate: rate)
        processor.update(boosted())
        processor.configure(sampleRate: rate, channelCount: 2)
        let source = tone(frames: 48_000, rate: rate)
        let description = try #require(EQStreamEngine.formatDescription(for: source.format))
        let sample = try #require(EQStreamEngine.sampleBuffer(from: source, skipping: 12_000,
                                                              at: CMTime(value: 12_000, timescale: 48_000),
                                                              description: description, processor: processor))
        #expect(CMSampleBufferGetNumSamples(sample) == 36_000)
        #expect(CMSampleBufferGetPresentationTimeStamp(sample).seconds == 0.25)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mChannelsPerFrame == 2 && asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)

        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var out = [Float](repeating: 0, count: 36_000 * 2)
        out.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        func rms(_ values: some Collection<Float>) -> Double {
            sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count))
        }
        let settled = 12_000 ..< 36_000
        let left = settled.map { out[$0 * 2] }, right = settled.map { out[$0 * 2 + 1] }
        let dry = rms((settled.lowerBound + 12_000 ..< settled.upperBound + 12_000).map { source.floatChannelData![0][$0] })
        // +9 dB at the band's centre, on both channels.
        #expect(abs(20 * log10(rms(left) / dry) - 9) < 0.3)
        #expect(abs(20 * log10(rms(right) / dry) - 9) < 0.3)
    }

    @Test func surroundKeepsItsLayout() throws {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let description = try #require(EQStreamEngine.formatDescription(for: format))
        var size = 0
        let carried = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size))
        #expect(carried.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_MPEG_5_1_A)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mChannelsPerFrame == 6)
    }

    // MARK: - On a player's clock

    /// A silent 8 s file for the player to play (its clock is all that is used).
    private func silentFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eqstream-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 8)!
        buffer.frameLength = 48_000 * 8
        try file.write(from: buffer)
        return url
    }

    /// A reader of an endless tone in 1024-frame chunks from `start`, beginning on a chunk
    /// boundary at or before it (as a segment would), and how many readers were made.
    private final class ToneReaders: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [Double] = []
        var starts: [Double] { lock.withLock { made } }
        func source() -> EQStreamSource {
            { [self] _, start in
                lock.withLock { made.append(start) }
                let rate = 48_000.0
                let position = Position(Int((start * rate / 1024).rounded(.down)) * 1024)
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
                return {
                    let frame = position.take(1024)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                    buffer.frameLength = 1024
                    for c in 0 ..< 2 {
                        for i in 0 ..< 1024 { buffer.floatChannelData![c][i] = 0.1 * Float(sin(Double(frame + i) * 0.13)) }
                    }
                    return EQStreamChunk(buffer: buffer, time: Double(frame) / rate)
                }
            }
        }
    }

    private final class Position: @unchecked Sendable {
        private let lock = NSLock()
        private var frame: Int
        init(_ frame: Int) { self.frame = frame }
        func take(_ count: Int) -> Int { lock.withLock { defer { frame += count }; return frame } }
    }

    private func wait(_ seconds: Double, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// The renderer's time minus the item's, at one host instant.
    private func offset(_ playback: EQStreamPlayback) throws -> Double {
        let timebase = try #require(playback.item?.timebase)
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        let ours = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: playback.engine.synchronizer.timebase).seconds
        let theirs = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: timebase).seconds
        return ours - theirs
    }

    @Test func followsThePlayersClockAndHandsItsSoundBack() async throws {
        let url = try silentFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let eq = RAVEAudioEQ(defaults: suite(), saveDelay: .zero)
        eq.settings = boosted()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        let readers = ToneReaders()
        #expect(eq.attachStream(to: item, player: player, source: readers.source()) == .streamed)
        let playback = try #require(eq.streamPlayback(for: item))

        await wait(5) { item.status == .readyToPlay }
        player.play()
        await wait(3) { playback.isSounding }
        #expect(playback.isSounding)
        #expect(player.isMuted, "the player is silenced under the EQ's sound")
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(try offset(playback)) < 0.035)
        #expect(playback.engine.renderer.status == .rendering)
        #expect(playback.engine.synchronizer.rate == 1)

        // The listener unmutes: the player stays muted, the renderer plays.
        player.isMuted = false
        #expect(player.isMuted)
        #expect(!playback.isListenerMuted)
        #expect(!playback.engine.renderer.isMuted)

        // Pause: the renderer stops with it.
        player.pause()
        await wait(1) { playback.engine.synchronizer.rate == 0 }
        #expect(playback.engine.synchronizer.rate == 0)

        // Seek and play on: a new read from the target, the clock with it.
        let made = readers.starts.count
        await player.seek(to: CMTime(seconds: 5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        await wait(3) { readers.starts.count > made && playback.isSounding && playback.engine.synchronizer.rate == 1 }
        #expect(readers.starts.count > made)
        #expect(abs((readers.starts.last ?? 0) - 5) < 0.3)
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(try offset(playback)) < 0.035)

        // The EQ goes off: the player's own sound again, as the listener left it (unmuted).
        eq.setEnabled(false)
        await wait(1) { !playback.isSounding }
        #expect(!playback.isSounding)
        #expect(!player.isMuted)
        player.pause()
    }

    @Test func aFailingReaderGivesThePlayerItsSoundBack() async throws {
        let url = try silentFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let eq = RAVEAudioEQ(defaults: suite(), saveDelay: .zero)
        eq.settings = boosted()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        var results: [EQAttachResult] = []
        eq.attachStream(to: item, player: player, source: { _, _ in
            { throw URLError(.badServerResponse) }
        }, onResult: { results.append($0) })
        let playback = try #require(eq.streamPlayback(for: item))
        await wait(5) { item.status == .readyToPlay }
        player.play()
        await wait(3) { playback.failure != nil }
        #expect(playback.failure != nil)
        #expect(!playback.isSounding)
        #expect(!player.isMuted)
        #expect(results.contains { if case .failed = $0 { true } else { false } })
        player.pause()
    }
}
