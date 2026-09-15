import Foundation
import Testing
@testable import RAVECamera

/// The container arithmetic both consumers depend on. The builder tests came
/// from Raven's `AVCCBuilderTests` and the splitter tests from Longwave's
/// `RTPPacketizerTests` when the two files converged here; Raven keeps the one
/// test that needs its own parser — the round trip through `AVCCConfig`.
@Suite("AVCC boxes and access units")
struct RAVEAVCCTests {
    private let sps = Data([0x67, 0x64, 0x00, 0x28, 0xAC, 0xB2])
    private let pps = Data([0x68, 0xEE, 0x3C, 0xB0])

    // MARK: - Building a box

    @Test func writesTheBoxLayoutADecoderExpects() throws {
        let box = try #require(RAVEAVCC.avcC(sps: sps, pps: pps, nalUnitLengthSize: 4))
        let bytes = [UInt8](box)
        #expect(bytes[0] == 1, "configurationVersion")
        #expect(Array(bytes[1...3]) == [0x64, 0x00, 0x28], "profile, compat, level come from the SPS")
        #expect(bytes[4] == 0xFF, "reserved bits set, lengthSizeMinusOne = 3")
        #expect(bytes[5] == 0xE1, "reserved bits set, one SPS")
        #expect(Array(bytes[6...7]) == [0x00, 0x06])
        #expect(Array(bytes[8..<14]) == [UInt8](sps))
        #expect(bytes[14] == 1, "one PPS")
        #expect(Array(bytes[15...16]) == [0x00, 0x04])
        #expect(Array(bytes[17...]) == [UInt8](pps))
    }

    /// The decode side walks access units by this prefix size; the box must
    /// carry whatever VideoToolbox reported, not assume 4.
    @Test(arguments: [1, 2, 4])
    func preservesTheNalLengthSize(size: Int) throws {
        let box = try #require(RAVEAVCC.avcC(sps: sps, pps: pps, nalUnitLengthSize: size))
        #expect(Int([UInt8](box)[4] & 0x03) + 1 == size)
    }

    @Test func rejectsInvalidNalLengthSizes() {
        #expect(RAVEAVCC.avcC(sps: sps, pps: pps, nalUnitLengthSize: 3) == nil)
        #expect(RAVEAVCC.avcC(sps: sps, pps: pps, nalUnitLengthSize: 0) == nil)
    }

    /// The profile/level bytes come out of the SPS, so an SPS too short to
    /// hold them cannot produce a box.
    @Test func rejectsDegenerateParameterSets() {
        #expect(RAVEAVCC.avcC(sps: Data([0x67, 0x64]), pps: pps, nalUnitLengthSize: 4) == nil)
        #expect(RAVEAVCC.avcC(sps: sps, pps: Data(), nalUnitLengthSize: 4) == nil)
    }

    /// The codec string is the SPS's own profile/compat/level bytes verbatim —
    /// High 4.0 here — not a table lookup that could disagree with them.
    @Test func codecStringEchoesTheSPS() {
        #expect(RAVEAVCC.codecString(sps: sps) == "avc1.640028")
        #expect(RAVEAVCC.codecString(sps: Data([0x67, 0x42, 0xE0, 0x28])) == "avc1.42E028")
        #expect(RAVEAVCC.codecString(sps: Data([0x67])) == nil)
    }

    // MARK: - Splitting an access unit

    @Test func splitsLengthPrefixedUnits() {
        var avcc = Data()
        let nal1: [UInt8] = [0x65, 0x01, 0x02]
        let nal2: [UInt8] = [0x41, 0xFF]
        avcc.append(contentsOf: [0, 0, 0, 3]); avcc.append(contentsOf: nal1)
        avcc.append(contentsOf: [0, 0, 0, 2]); avcc.append(contentsOf: nal2)
        let units = RAVEAVCC.nalUnits(fromAVCC: avcc)
        #expect(units.count == 2)
        #expect([UInt8](units[0]) == nal1)
        #expect([UInt8](units[1]) == nal2)
    }

    @Test func honoursASmallerLengthPrefix() {
        let avcc = Data([0, 2, 0x65, 0xAA, 0, 1, 0x41])
        let units = RAVEAVCC.nalUnits(fromAVCC: avcc, nalUnitLengthSize: 2)
        #expect(units.map { [UInt8]($0) } == [[0x65, 0xAA], [0x41]])
    }

    /// A length that overruns the data yields nothing from that point, never a
    /// truncated unit.
    @Test func stopsAtATruncatedUnit() {
        var avcc = Data()
        avcc.append(contentsOf: [0, 0, 0, 10, 0x65])    // claims 10 bytes, has 1
        #expect(RAVEAVCC.nalUnits(fromAVCC: avcc).isEmpty)
    }
}
