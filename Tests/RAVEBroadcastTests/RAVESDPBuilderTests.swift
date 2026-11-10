import Foundation
import Testing
@testable import RAVEBroadcast

/// Ported from Longwave's `LongwaveTests/SDPBuilderTests.swift` with the code.
@Suite("SDP builder")
struct RAVESDPBuilderTests {

    // Minimal plausible SPS: NAL header 0x67, profile 0x64 (High),
    // constraints 0x00, level 0x28 (4.0).
    private let sps = Data([0x67, 0x64, 0x00, 0x28, 0xAC, 0xB2])
    private let pps = Data([0x68, 0xEE, 0x38, 0x80])

    @Test func videoOnlySDP() {
        let sdp = RAVESDPBuilder.build(sessionName: "Test", sps: sps, pps: pps, audioChannels: nil)
        #expect(sdp.contains("m=video 0 RTP/AVP 96"))
        #expect(sdp.contains("a=rtpmap:96 H264/90000"))
        #expect(sdp.contains("packetization-mode=1"))
        #expect(sdp.contains("profile-level-id=640028"))
        #expect(sdp.contains("sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())"))
        #expect(sdp.contains("a=control:trackID=0"))
        #expect(!(sdp.contains("m=audio")))
        #expect(sdp.hasSuffix("\r\n"))
    }

    @Test func audioTrackMono() {
        let sdp = RAVESDPBuilder.build(sessionName: "Test", sps: sps, pps: pps, audioChannels: 1)
        #expect(sdp.contains("m=audio 0 RTP/AVP 97"))
        #expect(sdp.contains("a=rtpmap:97 opus/48000/2"), "rtpmap channel count is always 2 per RFC 7587")
        #expect(sdp.contains("sprop-stereo=0"))
        #expect(sdp.contains("a=control:trackID=1"))
    }

    @Test func audioTrackStereo() {
        let sdp = RAVESDPBuilder.build(sessionName: "Test", sps: sps, pps: pps, audioChannels: 2)
        #expect(sdp.contains("sprop-stereo=1"))
    }

    @Test func shortSPSFallsBackToDefaultProfile() {
        let sdp = RAVESDPBuilder.build(sessionName: "Test", sps: Data([0x67]), pps: pps, audioChannels: nil)
        #expect(sdp.contains("profile-level-id=42C01F"))
    }

    @Test func cRLFLineEndings() {
        let sdp = RAVESDPBuilder.build(sessionName: "Test", sps: sps, pps: pps, audioChannels: 1)
        #expect(!(sdp.contains("\n\n")))
        #expect(sdp.components(separatedBy: "\r\n").count > 10)
    }
}
