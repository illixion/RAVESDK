import CoreGraphics
import Testing
@testable import RAVEMedia

@Suite("Packed stereo layout")
struct PackedStereoLayoutTests {
    @Test("Side by side puts the left eye in the left half")
    func sideBySideRegions() {
        let layout = RAVEPackedStereoLayout(arrangement: .sideBySide, isHalfResolution: false)
        #expect(layout.eyeRegion(.left).scale == SIMD2(0.5, 1))
        #expect(layout.eyeRegion(.left).offset == SIMD2(0, 0))
        #expect(layout.eyeRegion(.right).offset == SIMD2(0.5, 0))
    }

    @Test("Over under puts the left eye on top")
    func overUnderRegions() {
        let layout = RAVEPackedStereoLayout(arrangement: .overUnder, isHalfResolution: true)
        #expect(layout.eyeRegion(.left).scale == SIMD2(1, 0.5))
        #expect(layout.eyeRegion(.left).offset == SIMD2(0, 0))
        #expect(layout.eyeRegion(.right).offset == SIMD2(0, 0.5))
    }

    @Test("Reversed eyes and a mirror each swap; together they cancel")
    func swaps() {
        let reversed = RAVEPackedStereoLayout(arrangement: .sideBySide, isHalfResolution: false, eyesReversed: true)
        #expect(reversed.eyeRegion(.left).offset == SIMD2(0.5, 0))
        #expect(reversed.eyeRegion(.left, mirrored: true).offset == SIMD2(0, 0))
        let plain = RAVEPackedStereoLayout(arrangement: .overUnder, isHalfResolution: false)
        #expect(plain.eyeRegion(.left, mirrored: true).offset == SIMD2(0, 0.5))
    }

    @Test("Full-resolution eyes are half the frame; half-resolution eyes are the whole frame")
    func eyeSizes() {
        let packed = CGSize(width: 3840, height: 1080)
        #expect(RAVEPackedStereoLayout(arrangement: .sideBySide, isHalfResolution: false).eyeSize(packed: packed)
                == CGSize(width: 1920, height: 1080))
        #expect(RAVEPackedStereoLayout(arrangement: .sideBySide, isHalfResolution: true).eyeSize(packed: CGSize(width: 1920, height: 1080))
                == CGSize(width: 1920, height: 1080))
        #expect(RAVEPackedStereoLayout(arrangement: .overUnder, isHalfResolution: false).eyeSize(packed: CGSize(width: 1920, height: 2160))
                == CGSize(width: 1920, height: 1080))
        #expect(RAVEPackedStereoLayout(arrangement: .sideBySide, isHalfResolution: false).eyeSize(packed: CGSize(width: 3841, height: 1080)).width
                == 1920)
    }

    @Test("The frame's shape overrules a wrong half/full tag")
    func resolutionCorrection() {
        let half = RAVEPackedStereoLayout(arrangement: .sideBySide, isHalfResolution: true)
        // Jellyfin's "HalfSideBySide" on a 3840×1080 file: two full HD eyes.
        #expect(half.correctingResolution(forPacked: CGSize(width: 3840, height: 1080)).isHalfResolution == false)
        #expect(half.correctingResolution(forPacked: CGSize(width: 1920, height: 1080)).isHalfResolution == true)
        let full = RAVEPackedStereoLayout(arrangement: .sideBySide, isHalfResolution: false)
        #expect(full.correctingResolution(forPacked: CGSize(width: 1920, height: 1080)).isHalfResolution == true)
        // A half-SBS scope film: the full reading's 1.2:1 eye is implausible.
        #expect(full.correctingResolution(forPacked: CGSize(width: 1920, height: 800)).isHalfResolution == true)
        // Full-SBS 4:3 vs half-SBS 2.67:1: both plausible, the tag stands.
        #expect(full.correctingResolution(forPacked: CGSize(width: 2560, height: 960)).isHalfResolution == false)
        #expect(half.correctingResolution(forPacked: CGSize(width: 2560, height: 960)).isHalfResolution == true)
        let ou = RAVEPackedStereoLayout(arrangement: .overUnder, isHalfResolution: true)
        #expect(ou.correctingResolution(forPacked: CGSize(width: 1920, height: 2160)).isHalfResolution == false)
        #expect(ou.correctingResolution(forPacked: CGSize(width: 1920, height: 1080)).isHalfResolution == true)
    }
}
