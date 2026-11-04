import Foundation

/// What a player's picture is in dynamic range, named for a viewer: "HDR10",
/// "Dolby Vision 8.1", "HLG", "SDR", or what was lost on the way ("SDR,
/// tone-mapped from HDR10").
///
/// Two witnesses, and the frames win. What the decoded frames are
/// (`VideoFrameRange`: their transfer function and whether a Dolby Vision RPU
/// rides on them) is what is actually shown; what the source file is
/// (`VideoSourceRange`, from a server's metadata or the remux's own reading)
/// says what kind of HDR that is (HDR10+ and the Dolby Vision profile can't
/// be read off a frame) and what a transcode threw away.
public struct VideoDynamicRange: Equatable, Sendable {
    /// "HDR10", "Dolby Vision 8.1", "SDR".
    public var label: String
    /// What the label leaves out, when something did not come through:
    /// "tone-mapped from Dolby Vision 8.1", "Dolby Vision base layer only",
    /// "shown as SDR on this display".
    public var note: String?
    /// The picture is HDR as shown.
    public var isHDR: Bool
    /// The source had more than what plays (HDR lost, or Dolby Vision
    /// reduced to its base layer).
    public var isReduced: Bool

    public init(label: String, note: String? = nil, isHDR: Bool, isReduced: Bool = false) {
        self.label = label
        self.note = note
        self.isHDR = isHDR
        self.isReduced = isReduced
    }

    /// The name for what plays. `frames` nil (a player that can't say, such
    /// as a web view) names the source; both nil is nil. `displaysHDR` false
    /// is a display that tone-maps HDR (a Mac on an SDR screen).
    public static func describe(frames: VideoFrameRange?, source: VideoSourceRange?,
                                displaysHDR: Bool = true) -> VideoDynamicRange? {
        guard let frames else {
            guard let source else { return nil }
            return VideoDynamicRange(label: source.label, isHDR: source.isHDR && displaysHDR,
                                     isReduced: false).shown(displaysHDR: displaysHDR)
        }
        var result: VideoDynamicRange
        switch frames.transfer {
        case .sdr:
            if let source, source.isHDR {
                result = VideoDynamicRange(label: "SDR", note: "tone-mapped from \(source.label)",
                                           isHDR: false, isReduced: true)
            } else {
                result = VideoDynamicRange(label: "SDR", isHDR: false)
            }
        case .pq, .hlg:
            let base = frames.transfer == .hlg ? "HLG" : "HDR10"
            switch source?.kind {
            case .dolbyVision where frames.hasDolbyVisionRPU:
                result = VideoDynamicRange(label: source!.label, isHDR: true)
            case .dolbyVision:
                // The RPU didn't arrive (a server remux that drops it) or
                // isn't applied (the stereo players show the base layer).
                result = VideoDynamicRange(label: base, note: "Dolby Vision base layer only",
                                           isHDR: true, isReduced: true)
            case .hdr10Plus where frames.transfer == .pq:
                result = VideoDynamicRange(label: "HDR10+", isHDR: true)
            default:
                result = VideoDynamicRange(label: frames.hasDolbyVisionRPU ? "Dolby Vision" : base, isHDR: true)
            }
        }
        return result.shown(displaysHDR: displaysHDR)
    }

    private func shown(displaysHDR: Bool) -> VideoDynamicRange {
        guard isHDR, !displaysHDR else { return self }
        var copy = self
        copy.isHDR = false
        copy.note = [note, "shown as SDR on this display"].compactMap { $0 }.joined(separator: "; ")
        return copy
    }
}

/// What decoded frames say about themselves.
public struct VideoFrameRange: Equatable, Sendable {
    public enum Transfer: String, Sendable {
        case sdr, pq, hlg
    }

    public var transfer: Transfer
    /// A Dolby Vision RPU is attached to the frames (the system's renderer
    /// applies it; nothing else does).
    public var hasDolbyVisionRPU: Bool

    public init(transfer: Transfer, hasDolbyVisionRPU: Bool = false) {
        self.transfer = transfer
        self.hasDolbyVisionRPU = hasDolbyVisionRPU
    }

    /// From a CoreVideo transfer function name
    /// (`kCVImageBufferTransferFunctionKey`'s value).
    public init(transferFunction: String?, hasDolbyVisionRPU: Bool = false) {
        switch transferFunction {
        case "SMPTE_ST_2084_PQ": transfer = .pq
        case "ITU_R_2100_HLG": transfer = .hlg
        default: transfer = .sdr
        }
        self.hasDolbyVisionRPU = hasDolbyVisionRPU
    }
}

/// What a source file is, as its metadata says.
public struct VideoSourceRange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sdr, hdr10, hdr10Plus, hlg
        /// `profile` 5, 7, 8 or 10; `compatibility` the base layer's
        /// signal (8.1 HDR10, 8.2 SDR, 8.4 HLG).
        case dolbyVision(profile: Int?, compatibility: Int?)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var isHDR: Bool { kind != .sdr }

    /// "HDR10", "HDR10+", "HLG", "SDR", "Dolby Vision 8.1",
    /// "Dolby Vision 5", "Dolby Vision".
    public var label: String {
        switch kind {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .hlg: "HLG"
        case .dolbyVision(let profile?, let compatibility):
            if let compatibility, compatibility > 0, profile == 8 || profile == 10 {
                "Dolby Vision \(profile).\(compatibility)"
            } else {
                "Dolby Vision \(profile)"
            }
        case .dolbyVision(nil, _): "Dolby Vision"
        }
    }

    /// From Jellyfin's `VideoRangeType` (SDR, HDR10, HDR10Plus, HLG, DOVI,
    /// DOVIWithHDR10, DOVIWithHDR10Plus, DOVIWithHLG, DOVIWithSDR,
    /// DOVIWithEL, DOVIWithELHDR10Plus, DOVIInvalid) and its `DvProfile` /
    /// `DvBlSignalCompatibilityId`. Nil for Unknown or nothing.
    public init?(jellyfinRangeType: String?, dolbyVisionProfile: Int? = nil,
                 dolbyVisionCompatibility: Int? = nil) {
        guard let type = jellyfinRangeType?.uppercased(), !type.isEmpty, type != "UNKNOWN" else { return nil }
        if type.hasPrefix("DOVI"), type != "DOVIINVALID" {
            var compatibility = dolbyVisionCompatibility
            if compatibility == nil {
                compatibility = switch type {
                case "DOVIWITHHDR10", "DOVIWITHHDR10PLUS": 1
                case "DOVIWITHSDR": 2
                case "DOVIWITHHLG": 4
                default: nil
                }
            }
            kind = .dolbyVision(profile: dolbyVisionProfile, compatibility: compatibility)
            return
        }
        switch type {
        case "SDR": kind = .sdr
        case "HDR10", "DOVIINVALID": kind = .hdr10
        case "HDR10PLUS": kind = .hdr10Plus
        case "HLG": kind = .hlg
        default: return nil
        }
    }
}
