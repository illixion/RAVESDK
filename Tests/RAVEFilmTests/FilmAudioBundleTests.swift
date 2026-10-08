import AVFoundation
import Foundation
import Testing
@testable import RAVEFilm

/// Compressed object-audio bundles: bundles are built here the way the
/// plugin builds them (each channel a mono AAC stream of pre-roll + segment),
/// with Apple's AAC encoder standing in for the server's libfdk_aac.
@Suite("Film audio bundles")
struct FilmAudioBundleTests {
    static let rate = 48000

    @Test func decodesEachChannelInPlaceWithThePrerollDropped() throws {
        let frames = 2 * Self.rate, preroll = 4800
        let sources = (0 ..< 4).map { ch in Self.signal(count: preroll + frames, channel: ch) }
        let streams = try sources.map { try Self.encodeAAC($0) }
        let bundle = try FilmAudioBundle(data: Self.bundle(frames: frames, preroll: preroll, streams: streams))
        let decoded = bundle.decode(groups: [[0, 1], [2, 3]], deadline: nil, workers: 2)
        #expect(decoded.dropped == 0 && decoded.failed == 0)

        for ch in 0 ..< 4 {
            let plane = decoded.buffers[ch / 2].floatChannelData![ch % 2]
            let output = Array(UnsafeBufferPointer(start: plane, count: frames))
            let reference = Array(sources[ch][preroll...])
            // Best match at no shift: the encoder's priming and the pre-roll
            // are both gone, to the sample.
            let best = (-64 ... 64).max { Self.correlation(output, reference, lag: $0) < Self.correlation(output, reference, lag: $1) }
            print("channel \(ch): best alignment at \(best ?? 99), SNR \(Self.snrDB(output, reference)) dB")
            #expect(best == 0, "channel \(ch) is shifted by \(best ?? 99) samples")
            #expect(Self.snrDB(output, reference) > 15, "channel \(ch) SNR \(Self.snrDB(output, reference)) dB")
        }
    }

    /// Two consecutive segments decoded and laid end to end: with the
    /// pre-roll, the error at the join is no worse than inside a segment;
    /// encoded cold, it is.
    @Test func segmentsJoinWithoutAClick() throws {
        // Not a multiple of the chirp period, so the join lands mid-sweep.
        let segment = Self.rate * 137 / 100, preroll = 4800
        let source = Self.signal(count: 2 * segment, channel: 1)
        let first = try FilmAudioBundle(data: Self.bundle(frames: segment, preroll: 0, streams: [try Self.encodeAAC(Array(source[..<segment]))]))
        let warm = try FilmAudioBundle(data: Self.bundle(frames: segment, preroll: preroll,
                                                        streams: [try Self.encodeAAC(Array(source[(segment - preroll)...]))]))
        let cold = try FilmAudioBundle(data: Self.bundle(frames: segment, preroll: 0,
                                                        streams: [try Self.encodeAAC(Array(source[segment...]))]))
        func joined(_ second: FilmAudioBundle) -> [Float] {
            [first, second].flatMap { bundle -> [Float] in
                let buffer = bundle.decode(groups: [[0]], deadline: nil, workers: 1).buffers[0]
                return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: segment))
            }
        }
        func errorRMS(_ output: [Float], _ range: Range<Int>) -> Float {
            sqrt(range.map { pow(output[$0] - source[$0], 2) }.reduce(0, +) / Float(range.count))
        }
        let warmOut = joined(warm), coldOut = joined(cold)
        // The baseline: the same audio encoded as one continuous stream,
        // measured at the same place (AAC's error depends on the content).
        let whole = try FilmAudioBundle(data: Self.bundle(frames: 2 * segment, preroll: 0, streams: [try Self.encodeAAC(source)]))
        let wholeBuffer = whole.decode(groups: [[0]], deadline: nil, workers: 1).buffers[0]
        let continuous = Array(UnsafeBufferPointer(start: wholeBuffer.floatChannelData![0], count: 2 * segment))
        let join = (segment - 256) ..< (segment + 256)
        let baseline = errorRMS(continuous, join), warmJoin = errorRMS(warmOut, join), coldJoin = errorRMS(coldOut, join)
        print("error RMS at the join — one continuous stream \(baseline), segments with pre-roll \(warmJoin), without \(coldJoin)")
        // No click: the join is within the codec's own noise there.
        #expect(warmJoin < baseline * 2)
    }

    /// The scale the format is for: hundreds of channels in one bundle.
    @Test func decodesHundredsOfChannels() throws {
        let channels = 256, frames = 10 * Self.rate, preroll = 4800
        let stream = try Self.encodeAAC(Self.signal(count: preroll + frames, channel: 3))
        // Every eighth channel silent, as idle objects are.
        let streams = (0 ..< channels).map { $0 % 8 == 7 ? nil : stream }
        let bundle = try FilmAudioBundle(data: Self.bundle(frames: frames, preroll: preroll, streams: streams))
        let groups = stride(from: 0, to: channels, by: 8).map { Array($0 ..< min($0 + 8, channels)) }
        let workers = FilmServerClient.decodeWorkers
        let start = ContinuousClock.now
        let decoded = bundle.decode(groups: groups, deadline: nil, workers: workers)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        print("decoded \(channels - channels / 8) channels × 10 s in \(String(format: "%.2f", seconds)) s on \(workers) workers (\(String(format: "%.0f", 10 / seconds))× real time)")
        #expect(decoded.dropped == 0 && decoded.failed == 0)
        #expect(decoded.buffers.count == groups.count)
        #expect(decoded.buffers[0].floatChannelData![7][1000] == 0)
        #expect(decoded.buffers[0].floatChannelData![0][24000] != 0)
    }

    /// A device that can't decode a segment in time keeps the loudest
    /// channels and leaves the quietest silent.
    @Test func aMissedDeadlineDropsTheQuietestChannels() throws {
        let channels = 128, frames = 10 * Self.rate
        let stream = try Self.encodeAAC(Self.signal(count: frames, channel: 0))
        // Loudness descends with the channel index.
        let levels = (0 ..< channels).map { -10 - Float($0) * 0.3 }
        let bundle = try FilmAudioBundle(data: Self.bundle(frames: frames, preroll: 0, streams: Array(repeating: stream, count: channels), rmsDB: levels))
        let decoded = bundle.decode(groups: [Array(0 ..< channels)], deadline: .now + .milliseconds(150), workers: 2)
        let planes = decoded.buffers[0].floatChannelData!
        let kept = (0 ..< channels).filter { ch in (0 ..< frames).contains { planes[ch][$0] != 0 } }
        print("deadline: kept \(kept.count), dropped \(decoded.dropped)")
        #expect(decoded.dropped > 0)
        #expect(decoded.dropped + kept.count == channels)
        // Kept channels are exactly the loudest ones (a contiguous prefix,
        // give or take the ones in flight when the deadline passed).
        #expect(kept.max() ?? 0 < kept.count + 2)
    }

    @Test func rejectsWhatIsNotABundle() {
        #expect(throws: FilmAudioBundle.ParseError.self) { try FilmAudioBundle(data: Data("fLaC".utf8)) }
        var truncated = Self.bundle(frames: 10, preroll: 0, streams: [Data(count: 100)])
        truncated.removeLast(10)
        #expect(throws: FilmAudioBundle.ParseError.self) { try FilmAudioBundle(data: truncated) }
    }

    // MARK: Helpers

    /// A chirp per channel (repeating every 0.5 s, from a channel-specific
    /// start frequency): unlike a tone, it matches itself at one shift only.
    static func signal(count: Int, channel: Int) -> [Float] {
        let f0 = 200.0 * Double(channel + 1), sweep = 4000.0, period = 0.5
        return (0 ..< count).map { i in
            let t = Double(i) / Double(rate)
            let local = t.truncatingRemainder(dividingBy: period)
            return Float(0.3 * sin(2 * .pi * (f0 * local + sweep * local * local / (2 * period))))
        }
    }

    static func encodeAAC(_ samples: [Float], bitrate: Int = 64000) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitrate,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    /// The plugin's version-1 layout (CompressedSegments.cs).
    static func bundle(frames: Int, preroll: Int, streams: [Data?], rmsDB: [Float]? = nil) -> Data {
        var data = Data("AOB1".utf8)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(frames)); put(UInt32(preroll)); put(UInt32(streams.count))
        for (ch, stream) in streams.enumerated() {
            put(UInt32(stream?.count ?? 0))
            put((rmsDB?[ch] ?? -20).bitPattern)
            put(Float(-6).bitPattern)
        }
        for stream in streams { if let stream { data.append(stream) } }
        return data
    }

    static func correlation(_ a: [Float], _ b: [Float], lag: Int) -> Float {
        var sum: Float = 0
        for i in 1000 ..< (a.count - 1000) { sum += a[i] * b[i + lag] }
        return sum
    }

    static func snrDB(_ output: [Float], _ reference: [Float]) -> Float {
        var signal: Float = 0, noise: Float = 0
        for i in 0 ..< min(output.count, reference.count) {
            signal += reference[i] * reference[i]
            noise += pow(output[i] - reference[i], 2)
        }
        return 10 * log10(signal / max(noise, 1e-12))
    }
}
