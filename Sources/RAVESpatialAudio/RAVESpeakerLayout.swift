/*
 RAVESDK - standard speaker layouts as sound-stage sources

 Channel order is the Windows/WAVE (WAVEFORMATEXTENSIBLE) order, which is
 what GameStream/Sunshine, most game engines and Opus multistream surround
 deliver:

   2.0  FL FR
   5.1  FL FR FC LFE BL BR      (the WAVE "back" pair is 5.1's surrounds)
   7.1  FL FR FC LFE BL BR SL SR

 Angles follow ITU-R BS.775 for 5.1 (fronts ±30°, surrounds ±110°) and
 the usual 7.1 extension (sides ±90°, backs ±135°, within BS.2051's
 120–150° range). Azimuth is degrees clockwise from straight ahead, so +30
 is front right. Positions are in the stage's listener coordinates (−z
 forward, +x right, +y up, metres) at ear height.

 The LFE has no direction: it is a head-locked bed (`isLFE`), played dry.
 */

import simd

public struct RAVESpeaker: Sendable, Equatable {
    /// Index of this speaker's channel in an interleaved frame.
    public let channel: Int
    public let label: String
    /// Degrees clockwise from straight ahead; 0 for the LFE.
    public let azimuth: Float
    public let isLFE: Bool

    /// Where the speaker stands, `distance` metres from the listener; nil
    /// for the LFE.
    public func position(distance: Float) -> SIMD3<Float>? {
        guard !isLFE else { return nil }
        let radians = azimuth * .pi / 180
        return SIMD3(sinf(radians) * distance, 0, -cosf(radians) * distance)
    }
}

public enum RAVESpeakerLayout: String, CaseIterable, Sendable {
    case stereo = "2.0"
    case surround51 = "5.1"
    case surround71 = "7.1"

    /// The layout for an interleaved stream of `channelCount` channels.
    public init?(channelCount: Int) {
        switch channelCount {
        case 2: self = .stereo
        case 6: self = .surround51
        case 8: self = .surround71
        default: return nil
        }
    }

    public var channelCount: Int { speakers.count }

    /// Speakers in channel order.
    public var speakers: [RAVESpeaker] {
        switch self {
        case .stereo:
            [Self.speaker(0, "FL", -30), Self.speaker(1, "FR", 30)]
        case .surround51:
            [Self.speaker(0, "FL", -30), Self.speaker(1, "FR", 30), Self.speaker(2, "FC", 0),
             RAVESpeaker(channel: 3, label: "LFE", azimuth: 0, isLFE: true),
             Self.speaker(4, "BL", -110), Self.speaker(5, "BR", 110)]
        case .surround71:
            [Self.speaker(0, "FL", -30), Self.speaker(1, "FR", 30), Self.speaker(2, "FC", 0),
             RAVESpeaker(channel: 3, label: "LFE", azimuth: 0, isLFE: true),
             Self.speaker(4, "BL", -135), Self.speaker(5, "BR", 135),
             Self.speaker(6, "SL", -90), Self.speaker(7, "SR", 90)]
        }
    }

    private static func speaker(_ channel: Int, _ label: String, _ azimuth: Float) -> RAVESpeaker {
        RAVESpeaker(channel: channel, label: label, azimuth: azimuth, isLFE: false)
    }
}
