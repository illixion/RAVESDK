#if canImport(CoreVideo)
import CoreVideo
#endif
import Testing
@testable import RAVEMediaCore

@Suite struct VideoDynamicRangeTests {
    private func describe(_ frames: VideoFrameRange?, _ source: VideoSourceRange?, displaysHDR: Bool = true) -> VideoDynamicRange? {
        VideoDynamicRange.describe(frames: frames, source: source, displaysHDR: displaysHDR)
    }

    @Test func jellyfinRangeTypes() {
        #expect(VideoSourceRange(jellyfinRangeType: "SDR")?.label == "SDR")
        #expect(VideoSourceRange(jellyfinRangeType: "HDR10")?.label == "HDR10")
        #expect(VideoSourceRange(jellyfinRangeType: "HDR10Plus")?.label == "HDR10+")
        #expect(VideoSourceRange(jellyfinRangeType: "HLG")?.label == "HLG")
        #expect(VideoSourceRange(jellyfinRangeType: "DOVIWithHDR10", dolbyVisionProfile: 8)?.label == "Dolby Vision 8.1")
        #expect(VideoSourceRange(jellyfinRangeType: "DOVIWithHLG", dolbyVisionProfile: 8)?.label == "Dolby Vision 8.4")
        #expect(VideoSourceRange(jellyfinRangeType: "DOVI", dolbyVisionProfile: 5, dolbyVisionCompatibility: 0)?.label == "Dolby Vision 5")
        #expect(VideoSourceRange(jellyfinRangeType: "DOVIWithEL", dolbyVisionProfile: 7, dolbyVisionCompatibility: 6)?.label == "Dolby Vision 7")
        #expect(VideoSourceRange(jellyfinRangeType: "DOVI")?.label == "Dolby Vision")
        #expect(VideoSourceRange(jellyfinRangeType: "Unknown") == nil)
        #expect(VideoSourceRange(jellyfinRangeType: nil) == nil)
    }

    @Test func framesDecideWhatPlays() {
        let hdr10 = VideoSourceRange(kind: .hdr10)
        #expect(describe(.init(transfer: .pq), hdr10) == .init(label: "HDR10", isHDR: true))
        #expect(describe(.init(transfer: .hlg), nil) == .init(label: "HLG", isHDR: true))
        #expect(describe(.init(transfer: .pq, hasDolbyVisionRPU: true), nil)?.label == "Dolby Vision")
        #expect(describe(.init(transfer: .sdr), nil) == .init(label: "SDR", isHDR: false))
        #expect(describe(.init(transfer: .pq), VideoSourceRange(kind: .hdr10Plus))?.label == "HDR10+")
    }

    @Test func whatALossLooksLike() {
        // A server transcode to H.264 tone-maps.
        let dv = VideoSourceRange(kind: .dolbyVision(profile: 8, compatibility: 1))
        let lost = describe(.init(transfer: .sdr), dv)
        #expect(lost?.label == "SDR")
        #expect(lost?.note == "tone-mapped from Dolby Vision 8.1")
        #expect(lost?.isReduced == true)
        // The stereo players show 8.1's HDR10 base, RPU unapplied.
        let base = describe(.init(transfer: .pq), dv)
        #expect(base?.label == "HDR10")
        #expect(base?.note == "Dolby Vision base layer only")
        #expect(base?.isReduced == true)
        // With its RPU, it is what the source says.
        #expect(describe(.init(transfer: .pq, hasDolbyVisionRPU: true), dv) == .init(label: "Dolby Vision 8.1", isHDR: true))
    }

    @Test func anSDRDisplayTonemaps() {
        let shown = describe(.init(transfer: .pq), VideoSourceRange(kind: .hdr10), displaysHDR: false)
        #expect(shown?.label == "HDR10")
        #expect(shown?.isHDR == false)
        #expect(shown?.note == "shown as SDR on this display")
    }

    @Test func withoutFramesTheSourceIsNamed() {
        #expect(describe(nil, VideoSourceRange(kind: .hlg))?.label == "HLG")
        #expect(describe(nil, nil) == nil)
    }

    #if canImport(CoreVideo)
    @Test func coreVideoTransferNames() {
        #expect(VideoFrameRange(transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String).transfer == .pq)
        #expect(VideoFrameRange(transferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String).transfer == .hlg)
        #expect(VideoFrameRange(transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String).transfer == .sdr)
        #expect(VideoFrameRange(transferFunction: nil).transfer == .sdr)
    }
    #endif
}
