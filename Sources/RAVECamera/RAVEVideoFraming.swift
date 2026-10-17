/*
 RAVECamera - the wire format for encoded video between two processes on one
 device.

 Lifted from Raven's `BroadcastFraming` (the broadcast extension → app pipe)
 when a second pipe needed the same thing: spatial-ai-character publishing its
 rendered avatar as a camera that Raven's camera proxy subscribes to. Both are
 "here is how to configure a decoder, here are my frames" over loopback TCP,
 so both speak this, and each stream opens with its own magic so a client
 dialling the wrong port fails on the first four bytes instead of decoding
 another stream's frames.

 Everything length-prefixed, big-endian. The parser treats every length as
 hostile even though the peer is normally our own code: the port is plain
 loopback TCP, and anything local could connect to it. A bogus length must
 fail the connection, not size an allocation.

 Differences from the format it was lifted from, all backward-tolerant:
 - `config` carries the frame size after the record. A decoder doesn't need
   it, but a format description built from the record does (Raven's replay
   ring and preview), and the encoder's caller is the only one who knows it.
   A config without it parses as 0×0.
 - `keyframeRequest` flows the other way, subscriber to publisher: a
   subscriber that joined mid-GOP or had to drop asks for one rather than
   waiting out the GOP. The screen-share extension never reads it.
 - The magic is a parameter; `Parser(magic: nil)` reads the control
   direction, which opens with none.
 */

import Foundation

public enum RAVEVideoFraming {
    /// Raven's screen-share extension → app stream.
    public static let screenShareMagic = Data("RVN1".utf8)
    /// A virtual camera publisher → subscriber stream (`RAVEVirtualCamera`).
    public static let virtualCameraMagic = Data("RVC1".utf8)

    /// A 4K keyframe at these pipelines' bitrates is well under 2 MB; anything
    /// claiming more than this is a corrupt or hostile stream.
    public static let maxMessageLength = 8 * 1024 * 1024

    public enum Message: Equatable, Sendable {
        /// What a page's `VideoDecoder` needs, verbatim: an RFC 6381 codec
        /// string and the decoder configuration record (`avcC` or `hvcC`) as
        /// VideoToolbox built it, plus the frame size the encoder was created
        /// for. Sent once up front and again if the encoder ever changes them.
        ///
        /// Passing the record the encoder already produced is codec-neutral
        /// and lets the receiver forward it without parsing it; the original
        /// carried SPS/PPS and had to be reassembled for HEVC, which also has a
        /// VPS.
        case config(codecString: String, record: Data, width: Int, height: Int)
        /// One access unit in AVCC-style length-prefixed form, exactly as
        /// VideoToolbox emitted it.
        ///
        /// `capturedAtMs` and `encodedAtMs` are wall-clock epoch milliseconds:
        /// when the frame was produced and when the encoder handed it back. The
        /// epoch is the only clock two processes and a web page all share, and
        /// carrying both lets the far end attribute delay to a stage instead of
        /// to the pipeline as a whole. `nan` when the sender could not place
        /// the instant.
        case frame(data: Data, ptsMicroseconds: UInt64, keyframe: Bool,
                   capturedAtMs: Double, encodedAtMs: Double)
        /// Subscriber → publisher: make the next frame a keyframe.
        case keyframeRequest
    }

    private enum MessageType: UInt8 {
        case config = 1
        case frame = 2
        case keyframeRequest = 3
    }

    public enum ParseError: Error, Equatable {
        case badMagic
        case unknownMessageType(UInt8)
        case lengthOutOfBounds(Int)
        case truncatedPayload
    }

    // MARK: - Encoding

    public static func encode(_ message: Message) -> Data {
        var payload = Data()
        switch message {
        case .config(let codecString, let record, let width, let height):
            let codec = Data(codecString.utf8)
            payload.append(MessageType.config.rawValue)
            payload.append(UInt8(clamping: codec.count))
            payload.append(codec)
            appendU16(UInt16(clamping: record.count), to: &payload)
            payload.append(record)
            appendU16(UInt16(clamping: width), to: &payload)
            appendU16(UInt16(clamping: height), to: &payload)
        case .frame(let data, let pts, let keyframe, let capturedAtMs, let encodedAtMs):
            payload.append(MessageType.frame.rawValue)
            payload.append(keyframe ? 1 : 0)
            appendU64(pts, to: &payload)
            appendU64(capturedAtMs.bitPattern, to: &payload)
            appendU64(encodedAtMs.bitPattern, to: &payload)
            payload.append(data)
        case .keyframeRequest:
            payload.append(MessageType.keyframeRequest.rawValue)
        }
        var framed = Data()
        appendU32(UInt32(payload.count), to: &framed)
        framed.append(payload)
        return framed
    }

    // MARK: - Parsing

    /// Incremental: TCP gives no message boundaries, so feed it whatever
    /// arrived and it returns every complete message, keeping the tail.
    public struct Parser: Sendable {
        private let magic: Data?
        private var buffer = Data()
        private var sawMagic: Bool

        /// - Parameter magic: what the stream must open with, or nil for a
        ///   stream that opens straight into messages (the control direction).
        public init(magic: Data?) {
            self.magic = magic
            sawMagic = magic == nil
        }

        public mutating func consume(_ data: Data) throws -> [Message] {
            buffer.append(data)

            if !sawMagic, let magic {
                guard buffer.count >= magic.count else {
                    // Fail as soon as a prefix disagrees: an HTTP probe should
                    // not wait for four bytes it will never send.
                    guard magic.starts(with: buffer) else { throw ParseError.badMagic }
                    return []
                }
                guard buffer.prefix(magic.count) == magic else { throw ParseError.badMagic }
                buffer.removeFirst(magic.count)
                sawMagic = true
            }

            var messages: [Message] = []
            while true {
                guard buffer.count >= 4 else { break }
                let length = Int(readU32(buffer, at: buffer.startIndex))
                // Zero-length carries no type byte and can only loop forever.
                guard length >= 1, length <= maxMessageLength else {
                    throw ParseError.lengthOutOfBounds(length)
                }
                guard buffer.count >= 4 + length else { break }
                let payload = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + length))
                buffer.removeFirst(4 + length)
                messages.append(try parse(payload: payload))
            }
            return messages
        }

        private func parse(payload: Data) throws -> Message {
            let bytes = [UInt8](payload)
            guard let type = MessageType(rawValue: bytes[0]) else {
                throw ParseError.unknownMessageType(bytes[0])
            }
            switch type {
            case .config:
                // type(1) codecLen(1) codec recordLen(2) record [width(2) height(2)]
                var offset = 1
                guard bytes.count >= offset + 1 else { throw ParseError.truncatedPayload }
                let codecLength = Int(bytes[offset]); offset += 1
                guard bytes.count >= offset + codecLength + 2 else { throw ParseError.truncatedPayload }
                guard let codecString = String(bytes: bytes[offset..<(offset + codecLength)], encoding: .utf8) else {
                    throw ParseError.truncatedPayload
                }
                offset += codecLength
                let recordLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1]); offset += 2
                guard bytes.count >= offset + recordLength else { throw ParseError.truncatedPayload }
                let record = Data(bytes[offset..<(offset + recordLength)])
                offset += recordLength
                var width = 0, height = 0
                if bytes.count >= offset + 4 {
                    width = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                    height = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                }
                return .config(codecString: codecString, record: record, width: width, height: height)
            case .frame:
                // type(1) key(1) pts(8) capturedAt(8) encodedAt(8) data
                guard bytes.count >= 26 else { throw ParseError.truncatedPayload }
                let keyframe = bytes[1] != 0
                func readU64(at start: Int) -> UInt64 {
                    var value: UInt64 = 0
                    for i in 0..<8 { value = value << 8 | UInt64(bytes[start + i]) }
                    return value
                }
                return .frame(
                    data: Data(bytes[26...]), ptsMicroseconds: readU64(at: 2), keyframe: keyframe,
                    capturedAtMs: Double(bitPattern: readU64(at: 10)),
                    encodedAtMs: Double(bitPattern: readU64(at: 18))
                )
            case .keyframeRequest:
                return .keyframeRequest
            }
        }
    }

    // MARK: - Byte helpers

    private static func appendU16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func appendU64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func readU32(_ data: Data, at index: Data.Index) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value = value << 8 | UInt32(data[index + i]) }
        return value
    }
}
