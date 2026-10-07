/*
 RAVEMedia - packed stereo layout

 How a stereo video packs both eyes into one decoded frame: side by side or
 over/under, each eye either at full resolution (the frame is twice as wide or
 tall as one eye) or squeezed to half (the frame has the size of one eye, and
 each half has to be stretched back out). The stereo pump crops each eye out
 of the frame with these rectangles, so a packed 3D video plays as real stereo
 straight from the decoder, with no conversion to MV-HEVC first.

 Pure geometry, no platform gate, so the rectangles are unit-tested on macOS.
 */

import CoreGraphics

public struct RAVEPackedStereoLayout: Hashable, Sendable, Codable {
    public enum Arrangement: String, Hashable, Sendable, Codable {
        /// Left eye in the left half.
        case sideBySide
        /// Left eye in the top half.
        case overUnder
    }

    public enum Eye: Sendable {
        case left, right
    }

    public var arrangement: Arrangement
    /// Each eye is squeezed to half width (side by side) or half height (over
    /// under), so the packed frame has the display size of one eye.
    public var isHalfResolution: Bool
    /// The file stores the right eye where the left belongs.
    public var eyesReversed: Bool

    public init(arrangement: Arrangement, isHalfResolution: Bool, eyesReversed: Bool = false) {
        self.arrangement = arrangement
        self.isHalfResolution = isHalfResolution
        self.eyesReversed = eyesReversed
    }

    /// Where `eye` sits in the packed frame, in normalized coordinates with the
    /// origin at the top left: `sample = uv * scale + offset`.
    ///
    /// - Parameter mirrored: the picture is flipped horizontally. A mirrored
    ///   stereo pair is only a valid pair with the eyes exchanged — the mirror
    ///   image of what the left eye saw is what a right eye would see — so a
    ///   flip without the swap inverts the depth.
    public func eyeRegion(_ eye: Eye, mirrored: Bool = false) -> (scale: SIMD2<Float>, offset: SIMD2<Float>) {
        let swapped = eyesReversed != mirrored
        let second = (eye == .right) != swapped
        switch arrangement {
        case .sideBySide:
            return (SIMD2(0.5, 1), SIMD2(second ? 0.5 : 0, 0))
        case .overUnder:
            return (SIMD2(1, 0.5), SIMD2(0, second ? 0.5 : 0))
        }
    }

    /// This layout with `isHalfResolution` corrected by the frame's shape.
    ///
    /// The tag that says "half" or "full" is often wrong: Jellyfin reads a
    /// plain `.3D.SBS.` file name as half side by side, so a 3840×1080 film
    /// (two 1920×1080 eyes) came out with each eye stretched to 3.56:1. One of
    /// the two readings usually gives an eye no picture is shaped like, and
    /// then the other one wins. When both are plausible (a full side-by-side
    /// 4:3 film is also a plausible half side-by-side scope film) the tag
    /// stands.
    public func correctingResolution(forPacked packed: CGSize) -> RAVEPackedStereoLayout {
        guard packed.width > 0, packed.height > 0 else { return self }
        func aspect(half: Bool) -> CGFloat {
            var layout = self
            layout.isHalfResolution = half
            let eye = layout.eyeSize(packed: packed)
            return eye.width / max(eye.height, 1)
        }
        let halfFits = Self.plausibleEyeAspect.contains(aspect(half: true))
        let fullFits = Self.plausibleEyeAspect.contains(aspect(half: false))
        guard halfFits != fullFits else { return self }
        var corrected = self
        corrected.isHalfResolution = halfFits
        return corrected
    }

    /// Eye shapes real pictures have: 4:3 up to Ultra Panavision's 2.76:1.
    static let plausibleEyeAspect: ClosedRange<CGFloat> = 1.25...2.8

    /// The display size of one eye for a packed frame of `packed` pixels.
    public func eyeSize(packed: CGSize) -> CGSize {
        if isHalfResolution { return packed }
        switch arrangement {
        case .sideBySide: return CGSize(width: (packed.width / 2).rounded(.down), height: packed.height)
        case .overUnder: return CGSize(width: packed.width, height: (packed.height / 2).rounded(.down))
        }
    }
}
