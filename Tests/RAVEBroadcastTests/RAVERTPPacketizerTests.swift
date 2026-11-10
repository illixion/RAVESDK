import Foundation
import Testing
@testable import RAVEBroadcast

/// Ported from Longwave's `LongwaveTests/RTPPacketizerTests.swift` with the code.
@Suite("RTP packetizers")
struct RAVERTPPacketizerTests {

    // MARK: - RTP header

    @Test func headerEncoding() {
        let header = RAVERTPHeader.encode(marker: true, payloadType: 96, sequenceNumber: 0xABCD,
                                      timestamp: 0x01020304, ssrc: 0xDEADBEEF)
        #expect(header.count == 12)
        let bytes = [UInt8](header)
        #expect(bytes[0] == 0x80)                       // V=2, no P/X/CC
        #expect(bytes[1] == 0x80 | 96)                  // marker + PT
        #expect(bytes[2] == 0xAB)
        #expect(bytes[3] == 0xCD)
        #expect(Array(bytes[4...7]) == [0x01, 0x02, 0x03, 0x04])
        #expect(Array(bytes[8...11]) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test func headerNoMarker() {
        let header = RAVERTPHeader.encode(marker: false, payloadType: 97, sequenceNumber: 0,
                                      timestamp: 0, ssrc: 1)
        #expect([UInt8](header)[1] == 97)
    }

    // AVCC splitting moved to RAVESDK (`RAVEAVCC.nalUnits(fromAVCC:)`) along
    // with the encoder; its tests live in `RAVECameraTests` there.

    // MARK: - H.264 single NAL

    @Test func singleNALPacket() {
        var packetizer = RAVEH264Packetizer(ssrc: 42, maxPayloadSize: 1200, initialSequenceNumber: 100)
        let nal = Data([0x65] + [UInt8](repeating: 0xAA, count: 50))
        let packets = packetizer.packetize(nalUnits: [nal], timestamp: 9000)
        #expect(packets.count == 1)
        let bytes = [UInt8](packets[0])
        #expect(bytes[1] == 0x80 | 96, "marker must be set on the last packet of an access unit")
        #expect(Array(bytes[12...]) == [UInt8](nal), "single-NAL payload is the NAL verbatim")
        #expect(packetizer.sequenceNumber == 101)
    }

    @Test func markerOnlyOnLastNAL() {
        var packetizer = RAVEH264Packetizer(ssrc: 1)
        let sps = Data([0x67, 0x01]), pps = Data([0x68, 0x02]), idr = Data([0x65, 0x03])
        let packets = packetizer.packetize(nalUnits: [sps, pps, idr], timestamp: 0)
        #expect(packets.count == 3)
        #expect([UInt8](packets[0])[1] & 0x80 == 0)
        #expect([UInt8](packets[1])[1] & 0x80 == 0)
        #expect([UInt8](packets[2])[1] & 0x80 == 0x80)
    }

    // MARK: - FU-A fragmentation

    @Test func fUAFragmentationRoundTrip() {
        let maxPayload = 100
        var packetizer = RAVEH264Packetizer(ssrc: 7, maxPayloadSize: maxPayload, initialSequenceNumber: 0)
        let originalNAL = Data([0x65] + (0..<350).map { UInt8(truncatingIfNeeded: $0) })
        let packets = packetizer.packetize(nalUnits: [originalNAL], timestamp: 1234)

        #expect(packets.count > 1)
        var reassembled = Data()
        for (index, packet) in packets.enumerated() {
            let bytes = [UInt8](packet)
            let payload = Array(bytes[12...])
            #expect(payload.count <= maxPayload + 2)
            let fuIndicator = payload[0]
            let fuHeader = payload[1]
            #expect(fuIndicator & 0x1F == 28, "FU-A type")
            #expect(fuIndicator & 0xE0 == 0x65 & 0xE0, "F/NRI preserved")
            #expect(fuHeader & 0x1F == 0x65 & 0x1F, "original NAL type in FU header")
            let isFirst = index == 0
            let isLast = index == packets.count - 1
            #expect((fuHeader & 0x80 != 0) == isFirst, "start bit")
            #expect((fuHeader & 0x40 != 0) == isLast, "end bit")
            #expect((bytes[1] & 0x80 != 0) == isLast, "marker on final fragment only")
            if isFirst {
                reassembled.append(0x65)    // reconstruct NAL header from FU bits
            }
            reassembled.append(contentsOf: payload[2...])
            // Sequence numbers must be contiguous.
            #expect(Int(bytes[2]) << 8 | Int(bytes[3]) == index)
        }
        #expect(reassembled == originalNAL)
    }

    @Test func sequenceNumberWraps() {
        var packetizer = RAVEH264Packetizer(ssrc: 1, initialSequenceNumber: 0xFFFF)
        _ = packetizer.packetize(nalUnits: [Data([0x41, 0x00])], timestamp: 0)
        #expect(packetizer.sequenceNumber == 0)
    }

    // MARK: - Opus

    @Test func opusPacket() {
        var packetizer = RAVEOpusPacketizer(ssrc: 9, initialSequenceNumber: 5)
        let frame = Data([0x78, 0x01, 0x02, 0x03])
        let packet = packetizer.packetize(frame: frame, timestamp: 960)
        let bytes = [UInt8](packet)
        #expect(bytes[1] == 97, "marker must be 0 for Opus (RFC 7587)")
        #expect(Array(bytes[12...]) == [UInt8](frame))
        #expect(packetizer.sequenceNumber == 6)
    }

    // MARK: - RTCP sender report

    @Test func senderReportLayout() {
        let report = RAVERTCPSenderReport.encode(ssrc: 0x11223344, ntpTime: 0xAABBCCDD_EEFF0011,
                                             rtpTimestamp: 90_000, packetCount: 10, octetCount: 999)
        #expect(report.count == 28)
        let bytes = [UInt8](report)
        #expect(bytes[0] == 0x80)
        #expect(bytes[1] == 200)
        #expect(Int(bytes[2]) << 8 | Int(bytes[3]) == 6, "length in 32-bit words minus one")
        #expect(Array(bytes[4...7]) == [0x11, 0x22, 0x33, 0x44])
        #expect(Array(bytes[8...15]) == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11])
    }

    @Test func nTPTimestampEpoch() {
        // Unix epoch == 2,208,988,800 s after the NTP epoch.
        let ntp = RAVERTCPSenderReport.ntpTimestamp(unixTime: 0)
        #expect(ntp >> 32 == 2_208_988_800)
    }
}
