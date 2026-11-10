import AVFAudio
import Foundation
import Testing
@testable import RAVEBroadcast

/// The native Opus encoder: a frame a packet, and the explicit timestamps a
/// delayed source passes.
@Suite("Opus encoder")
struct RAVEOpusEncoderTests {
    final class Packets: @unchecked Sendable {
        var frames: [(Data, UInt32)] = []
    }

    static func tone(frames: Int, hz: Double = 440) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = Float(0.3 * sin(2 * .pi * hz * Double(i) / 48_000)) }
        return buffer
    }

    @Test func explicitTimestampsFollowTheSourceAcrossAJump() throws {
        let encoder = RAVEOpusEncoder(channels: 1)
        let packets = Packets()
        encoder.onEncodedFrame = { packets.frames.append(($0, $1)) }
        var failure: String?
        encoder.onError = { failure = $0 }
        for tick in 0..<50 { encoder.encode(Self.tone(frames: 960), timestamp48k: UInt32(tick * 960)) }
        // The source jumped (a flushed delay): the timestamps jump with it.
        for tick in 0..<10 { encoder.encode(Self.tone(frames: 960), timestamp48k: 10_000_000 + UInt32(tick * 960)) }
        try #require(failure == nil, "native Opus should exist on this host")
        #expect(packets.frames.count >= 55)
        #expect(packets.frames.allSatisfy { !$0.0.isEmpty && $0.0.count < 1500 })
        let stamps = packets.frames.map(\.1)
        #expect(stamps.first == 0)
        #expect(stamps.prefix(40).enumerated().allSatisfy { $0.element == UInt32($0.offset * 960) })
        #expect(stamps.contains(10_000_000))
    }

    @Test func theRunningTimestampStepsByAFrame() {
        let encoder = RAVEOpusEncoder(channels: 1)
        let packets = Packets()
        encoder.onEncodedFrame = { packets.frames.append(($0, $1)) }
        encoder.encode(Self.tone(frames: 48_000))
        let stamps = packets.frames.map(\.1)
        #expect(stamps.count >= 45)
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $1 &- $0 == 960 })
    }
}
