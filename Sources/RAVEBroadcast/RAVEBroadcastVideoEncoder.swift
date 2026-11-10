import CoreMedia
import CoreVideo
import Foundation
import RAVECamera

/// The RTP-facing shape of `RAVEH264Encoder` (`RAVECamera`): the session
/// tuning — realtime, no B-frames, 1 s GOP — lives there, shared with
/// Raven's screen-share extension. What this adds is what RTP wants and a
/// WebCodecs decoder does not: each access unit split into raw NAL units
/// (RFC 6184 payloads them one at a time), with SPS/PPS prepended in-band
/// ahead of every IDR so readers that join mid-stream, and publishers coming
/// back from a reconnect, decode without an out-of-band SDP refresh.
///
/// Runs entirely on the caller's thread and VideoToolbox's output thread,
/// like the encoder it wraps.
///
/// Lifted from Longwave's `BroadcastCore/BroadcastVideoEncoder.swift`
/// (2026-11-10); adds the pixel-buffer entry point, a configurable profile
/// and GOP, and the keyframe request a rendered (rather than captured) source
/// needs.
public final class RAVEBroadcastVideoEncoder: @unchecked Sendable {

    /// Fired once when SPS/PPS first become available (and again if they
    /// change) — gates RTSP ANNOUNCE, which embeds them in the SDP.
    public nonisolated(unsafe) var onParameterSets: ((_ sps: Data, _ pps: Data) -> Void)?
    /// One access unit: raw NALs (SPS/PPS prepended on keyframes), PTS,
    /// keyframe flag. Fires on the VideoToolbox output thread.
    public nonisolated(unsafe) var onEncodedFrame: ((_ nalUnits: [Data], _ pts: CMTime, _ keyframe: Bool) -> Void)?
    public nonisolated(unsafe) var onError: ((String) -> Void)?

    private let encoder: RAVEH264Encoder
    private nonisolated(unsafe) var parameterSets: RAVEH264Encoder.ParameterSets?

    public init(bitrate: Int, frameRate: Int = 30, keyframeInterval: TimeInterval = 1,
                profile: RAVEH264Encoder.Profile = .main) {
        encoder = RAVEH264Encoder(configuration: .init(bitrate: bitrate, frameRate: frameRate,
                                                       keyframeInterval: keyframeInterval, profile: profile))
        encoder.onParameterSets = { [weak self] sets in
            guard let self else { return }
            self.parameterSets = sets
            self.onParameterSets?(sets.sps, sets.pps)
        }
        encoder.onAccessUnit = { [weak self] unit in
            guard let self else { return }
            var nalUnits = RAVEAVCC.nalUnits(fromAVCC: unit.data,
                                             nalUnitLengthSize: self.parameterSets?.nalUnitLengthSize ?? 4)
            guard !nalUnits.isEmpty else { return }
            if unit.isKeyframe, let sets = self.parameterSets {
                nalUnits.insert(contentsOf: [sets.sps, sets.pps], at: 0)
            }
            self.onEncodedFrame?(nalUnits, unit.presentationTime, unit.isKeyframe)
        }
        encoder.onError = { [weak self] message in
            self?.onError?(message)
        }
    }

    public func encode(_ sampleBuffer: CMSampleBuffer) {
        encoder.encode(sampleBuffer)
    }

    public func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        encoder.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }

    /// The next frame is encoded as an IDR.
    public func requestKeyframe() {
        encoder.requestKeyframe()
    }

    public func invalidate() {
        encoder.invalidate()
        parameterSets = nil
    }
}
