/*
 RAVECamera - the AVCC container, both directions.

 VideoToolbox emits H.264 access units in AVCC form — every NAL unit prefixed
 with its length — and describes the stream out of band with SPS/PPS parameter
 sets. Every consumer of `RAVEH264Encoder` then wants one of two things done
 with that:

 - **An RTP publisher wants the NAL units back out**, one at a time
   (RFC 6184 payloads them individually). That is `nalUnits(fromAVCC:)`,
   lifted from Longwave's `AVCCSplitter`.
 - **A WebCodecs `VideoDecoder` wants the access unit exactly as emitted**,
   plus an `avcC` configuration box as its `description` and an
   `avc1.PPCCLL` codec string. Those are `avcC(sps:pps:nalUnitLengthSize:)`
   and `codecString(sps:)`, lifted from Raven's `AVCCBuilder`.

 The codec string is not a lookup table: profile, constraint flags and level
 are literally the second, third and fourth bytes of the SPS NAL, hex-encoded.
 The encoder already chose them; this just repeats what it said.

 Raven's `AVCCConfig` (the *parser* for boxes a WebCodecs encoder produced) is
 this builder's exact inverse, and Raven's round-trip test pins the two file
 formats together. Change the layout here and that test is what says so.
 */

import Foundation

public enum RAVEAVCC {
    /// One SPS and one PPS is all `RAVEH264Encoder` produces; the box format
    /// allows more and parsers accept more, but building more would mean the
    /// encoder changed and this file should too.
    ///
    /// Returns nil for anything that cannot be a valid box: an SPS too short
    /// to hold the profile/level bytes, an empty PPS, a set longer than its
    /// UInt16 length field, or a NAL length-prefix size AVCC does not define.
    public static func avcC(sps: Data, pps: Data, nalUnitLengthSize: Int) -> Data? {
        guard sps.count >= 4, sps.count <= Int(UInt16.max),
              !pps.isEmpty, pps.count <= Int(UInt16.max),
              [1, 2, 4].contains(nalUnitLengthSize) else { return nil }

        let spsBytes = [UInt8](sps)
        var box = Data()
        box.append(1)                                   // configurationVersion
        box.append(spsBytes[1])                         // AVCProfileIndication
        box.append(spsBytes[2])                         // profile_compatibility
        box.append(spsBytes[3])                         // AVCLevelIndication
        box.append(0xFC | UInt8(nalUnitLengthSize - 1)) // lengthSizeMinusOne
        box.append(0xE0 | 1)                            // numOfSequenceParameterSets
        box.append(UInt8(sps.count >> 8))
        box.append(UInt8(sps.count & 0xFF))
        box.append(sps)
        box.append(1)                                   // numOfPictureParameterSets
        box.append(UInt8(pps.count >> 8))
        box.append(UInt8(pps.count & 0xFF))
        box.append(pps)
        return box
    }

    /// `"avc1.640028"`-shaped string for `VideoDecoder.configure` — the SPS's
    /// own profile/compat/level bytes, verbatim.
    public static func codecString(sps: Data) -> String? {
        guard sps.count >= 4 else { return nil }
        let bytes = [UInt8](sps)
        return String(format: "avc1.%02X%02X%02X", bytes[1], bytes[2], bytes[3])
    }

    /// Splits an AVCC access unit (length-prefixed NAL units, as VideoToolbox
    /// emits them) into raw NAL units.
    ///
    /// Stops at the first length that runs past the end of the data rather
    /// than returning a truncated unit: a NAL cut short would be handed to a
    /// packetizer as if whole, and the far end's decoder would be the first to
    /// notice.
    public static func nalUnits(fromAVCC data: Data, nalUnitLengthSize: Int = 4) -> [Data] {
        let bytes = [UInt8](data)
        var nalUnits: [Data] = []
        var offset = 0
        while offset + nalUnitLengthSize <= bytes.count {
            var length = 0
            for i in 0..<nalUnitLengthSize { length = (length << 8) | Int(bytes[offset + i]) }
            offset += nalUnitLengthSize
            guard length > 0, offset + length <= bytes.count else { break }
            nalUnits.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        return nalUnits
    }
}
