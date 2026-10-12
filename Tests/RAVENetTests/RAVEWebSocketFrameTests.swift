/*
 Tests for the POSIX client's WebSocket framing (RFC 6455 §5).

 The three payload-length encodings each get a round trip, since a frame
 whose length field is off by one form reads as garbage from then on, and a
 split read must wait for the rest of the frame instead of misparsing it.
 */

import Foundation
import Testing
@testable import RAVENet

@Suite("WebSocket framing")
struct RAVEWebSocketFrameTests {
    private let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]

    @Test("The RFC's masked \"Hello\" example encodes byte for byte")
    func rfcExample() {
        let frame = RAVEWebSocketFrame.encode(opcode: .text, payload: Array("Hello".utf8), mask: mask)
        #expect(frame == [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58])
    }

    @Test("Each length encoding round-trips", arguments: [0, 125, 126, 65_535, 65_536, 200_000])
    func roundTrip(count: Int) throws {
        let payload = (0..<count).map { UInt8($0 % 251) }
        let frame = RAVEWebSocketFrame.encode(opcode: .binary, payload: payload, mask: mask)
        let parsed = try #require(try RAVEWebSocketFrame.parse(frame))
        #expect(parsed == .init(fin: true, opcode: .binary, payload: payload, length: frame.count))
    }

    @Test("An unmasked server frame parses, and a partial one waits")
    func serverFrame() throws {
        let frame: [UInt8] = [0x81, 0x05] + Array("Hello".utf8) + [0x89, 0x00]
        #expect(try RAVEWebSocketFrame.parse(Array(frame.prefix(4))) == nil)
        let first = try #require(try RAVEWebSocketFrame.parse(frame))
        #expect(first.opcode == .text && first.payload == Array("Hello".utf8) && first.length == 7)
        let ping = try #require(try RAVEWebSocketFrame.parse(Array(frame[7...])))
        #expect(ping.opcode == .ping && ping.payload.isEmpty)
    }

    @Test("A frame claiming more than the cap is refused before it's buffered")
    func oversized() {
        let header: [UInt8] = [0x82, 0x7F, 0, 0, 0, 0, 0x10, 0, 0, 0]
        #expect(throws: URLError.self) { try RAVEWebSocketFrame.parse(header) }
    }

    @Test("Unknown opcodes are a protocol error")
    func unknownOpcode() {
        #expect(throws: URLError.self) { try RAVEWebSocketFrame.parse([0x83, 0x00]) }
    }
}
