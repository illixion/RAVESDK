import Foundation
import Testing
@testable import RAVECamera

/// The framing is the contract two processes must agree on, and it crosses a
/// socket anything local could dial — so the parser is tested the way the AVCC
/// builder is: round trips for honesty, hostile input for safety, and
/// arbitrary fragmentation because TCP owes us no message boundaries. Moved
/// here from Raven's `BroadcastFramingTests` with the format.
@Suite("Video framing")
struct RAVEVideoFramingTests {
    private let magic = RAVEVideoFraming.virtualCameraMagic

    private func stream(_ messages: [RAVEVideoFraming.Message], magic: Data? = nil) -> Data {
        var data = magic ?? self.magic
        for message in messages { data.append(RAVEVideoFraming.encode(message)) }
        return data
    }

    private let config = RAVEVideoFraming.Message.config(
        codecString: "hvc1.1.6.L120.B0",
        record: Data([0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78]),
        width: 1280, height: 720
    )
    private let frame = RAVEVideoFraming.Message.frame(
        data: Data(repeating: 0xAB, count: 1000),
        ptsMicroseconds: 1_234_567_890_123,
        keyframe: true,
        capturedAtMs: 1_757_940_000_123.5,
        encodedAtMs: 1_757_940_000_145.25
    )

    @Test func roundTripsEveryMessageType() throws {
        var parser = RAVEVideoFraming.Parser(magic: magic)
        let out = try parser.consume(stream([config, frame, .keyframeRequest]))
        #expect(out == [config, frame, .keyframeRequest])
    }

    /// The control direction opens with no magic.
    @Test func parsesAStreamWithoutMagic() throws {
        var parser = RAVEVideoFraming.Parser(magic: nil)
        let out = try parser.consume(RAVEVideoFraming.encode(.keyframeRequest))
        #expect(out == [.keyframeRequest])
    }

    /// The screen-share extension's config predates the frame size; one
    /// without it reads as 0×0 rather than failing.
    @Test func readsAConfigWithoutFrameSize() throws {
        var payload = Data([1, 4])
        payload.append(contentsOf: Array("hvc1".utf8))
        payload.append(contentsOf: [0, 2, 0xAA, 0xBB])
        var wire = RAVEVideoFraming.screenShareMagic
        wire.append(contentsOf: [0, 0, 0, UInt8(payload.count)])
        wire.append(payload)
        var parser = RAVEVideoFraming.Parser(magic: RAVEVideoFraming.screenShareMagic)
        let out = try parser.consume(wire)
        #expect(out == [.config(codecString: "hvc1", record: Data([0xAA, 0xBB]), width: 0, height: 0)])
    }

    /// TCP can hand the parser any prefix of the stream. Every split point
    /// must produce the same messages, never an error and never a duplicate.
    @Test func reassemblesAcrossArbitrarySplits() throws {
        let wire = stream([config, frame, .frame(data: Data([1, 2, 3]), ptsMicroseconds: 7, keyframe: false,
                                                 capturedAtMs: 1, encodedAtMs: 2)])
        for splitAt in 1..<wire.count {
            var parser = RAVEVideoFraming.Parser(magic: magic)
            var out = try parser.consume(wire.prefix(splitAt))
            out += try parser.consume(wire.suffix(wire.count - splitAt))
            #expect(out.count == 3, "split at \(splitAt) produced \(out.count) messages")
        }
    }

    /// One byte at a time is the pathological fragmentation; if this holds,
    /// every realistic read size does too.
    @Test func reassemblesByteByByte() throws {
        let wire = stream([config, frame])
        var parser = RAVEVideoFraming.Parser(magic: magic)
        var out: [RAVEVideoFraming.Message] = []
        for byte in wire {
            out += try parser.consume(Data([byte]))
        }
        #expect(out == [config, frame])
    }

    /// A peer that opens with anything but the magic is not our stream.
    @Test func rejectsBadMagic() {
        var parser = RAVEVideoFraming.Parser(magic: magic)
        #expect(throws: RAVEVideoFraming.ParseError.badMagic) {
            _ = try parser.consume(Data("HTTP".utf8))
        }
    }

    /// The two streams' magics differ, so a client on the wrong port fails on
    /// the first byte that disagrees rather than decoding the other's frames.
    @Test func rejectsTheOtherStreamsMagicEarly() {
        var parser = RAVEVideoFraming.Parser(magic: RAVEVideoFraming.virtualCameraMagic)
        #expect(throws: RAVEVideoFraming.ParseError.badMagic) {
            _ = try parser.consume(RAVEVideoFraming.screenShareMagic.prefix(3))
        }
    }

    /// The reason lengths are validated before allocation: a hostile peer
    /// claiming a 2 GB message must fail the connection, not size a buffer.
    @Test func rejectsOversizedLength() {
        var wire = magic
        wire.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF])
        var parser = RAVEVideoFraming.Parser(magic: magic)
        #expect(throws: RAVEVideoFraming.ParseError.self) {
            _ = try parser.consume(wire)
        }
    }

    /// A zero-length message carries no type byte — accepting it would loop
    /// forever making no progress.
    @Test func rejectsZeroLength() {
        var wire = magic
        wire.append(contentsOf: [0, 0, 0, 0])
        var parser = RAVEVideoFraming.Parser(magic: magic)
        #expect(throws: RAVEVideoFraming.ParseError.self) {
            _ = try parser.consume(wire)
        }
    }

    @Test func rejectsUnknownMessageType() {
        var wire = magic
        wire.append(contentsOf: [0, 0, 0, 1, 99])
        var parser = RAVEVideoFraming.Parser(magic: magic)
        #expect(throws: RAVEVideoFraming.ParseError.unknownMessageType(99)) {
            _ = try parser.consume(wire)
        }
    }

    /// A config whose inner lengths overrun its outer frame.
    @Test func rejectsConfigWithLyingInnerLengths() {
        var payload = Data([1, 4])                 // type=config, codecLen=4
        payload.append(contentsOf: [0x61, 0x76, 0x63, 0x31])  // "avc1"
        payload.append(contentsOf: [0x40, 0x00])   // recordLen 16384 in a tiny payload
        payload.append(contentsOf: [1, 2, 3])
        var wire = magic
        wire.append(contentsOf: [0, 0, 0, UInt8(payload.count)])
        wire.append(payload)
        var parser = RAVEVideoFraming.Parser(magic: magic)
        #expect(throws: RAVEVideoFraming.ParseError.truncatedPayload) {
            _ = try parser.consume(wire)
        }
    }

    /// PTS is 64-bit on the wire; a value past 2^32 must survive.
    @Test func preservesLargeTimestamps() throws {
        let message = RAVEVideoFraming.Message.frame(
            data: Data([0]), ptsMicroseconds: UInt64(1) << 40, keyframe: false,
            capturedAtMs: 1_757_940_000_123.5, encodedAtMs: 1_757_940_000_145.25)
        var parser = RAVEVideoFraming.Parser(magic: magic)
        let out = try parser.consume(stream([message]))
        #expect(out == [message])
    }

    /// `nan` is how a sender says it could not place the capture instant, and
    /// it must arrive as `nan` rather than as a number — but `nan != nan`, so a
    /// frame carrying one is never compared by equality in a relay.
    @Test func carriesUnknownTimestampsAsNotANumber() throws {
        let message = RAVEVideoFraming.Message.frame(
            data: Data([0]), ptsMicroseconds: 1, keyframe: false,
            capturedAtMs: .nan, encodedAtMs: .nan)
        var parser = RAVEVideoFraming.Parser(magic: magic)
        let out = try parser.consume(stream([message]))
        guard case .frame(_, _, _, let captured, let encoded) = try #require(out.first) else {
            Issue.record("expected a frame message"); return
        }
        #expect(captured.isNaN)
        #expect(encoded.isNaN)
    }
}
