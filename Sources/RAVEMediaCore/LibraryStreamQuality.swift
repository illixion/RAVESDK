/*
 Hypnos - Library feature: streaming quality

 What a Library title is streamed at. `auto` plays the original (direct
 play, or a full-quality remux of a file Apple players can't open) and
 steps down a level when the stream can't keep up; `original` is the same
 start that never steps down ("Always Direct Play"); the rest cap the
 bitrate, so on a slow link a title can start low rather than stall on the
 original first.

 One preference for every title, chosen on the detail page or from the
 player: picking a level mid-film is also the answer for the next one.
 */

import Foundation

public enum LibraryStreamQuality: String, CaseIterable, Codable, Sendable {
    case auto
    case original
    case mbps40
    case mbps30
    case mbps20
    case mbps10
    case mbps4
    case mbps1_5

    public static let defaultsKey = "library.streamQuality"

    /// The saved preference.
    public static var preferred: LibraryStreamQuality {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The capped levels, highest first: what `auto` steps down through.
    public static let capped: [LibraryStreamQuality] = [.mbps40, .mbps30, .mbps20, .mbps10, .mbps4, .mbps1_5]

    /// Total bitrate (video + audio), or nil for the original.
    public var maxBitrate: Int? {
        switch self {
        case .auto, .original: nil
        case .mbps40: 40_000_000
        case .mbps30: 30_000_000
        case .mbps20: 20_000_000
        case .mbps10: 10_000_000
        case .mbps4: 4_000_000
        case .mbps1_5: 1_500_000
        }
    }

    /// The largest picture worth sending at the bitrate.
    public var maxWidth: Int? {
        switch self {
        case .auto, .original: nil
        case .mbps40: 3840
        case .mbps30: 2560
        case .mbps20, .mbps10: 1920
        case .mbps4: 1280
        case .mbps1_5: 854
        }
    }

    public var maxHeight: Int? {
        switch self {
        case .auto, .original: nil
        case .mbps40: 2160
        case .mbps30: 1440
        case .mbps20, .mbps10: 1080
        case .mbps4: 720
        case .mbps1_5: 480
        }
    }

    /// Audio within the cap: 5.1 AAC down to 1080p, stereo below.
    public var audioBitrate: Int {
        switch self {
        case .mbps4: 256_000
        case .mbps1_5: 128_000
        default: 640_000
        }
    }

    public var audioChannels: Int {
        switch self {
        case .mbps4, .mbps1_5: 2
        default: 6
        }
    }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .original: "Always Direct Play"
        case .mbps40: "4K · 40 Mbps"
        case .mbps30: "1440p · 30 Mbps"
        case .mbps20: "1080p · 20 Mbps"
        case .mbps10: "1080p · 10 Mbps"
        case .mbps4: "720p · 4 Mbps"
        case .mbps1_5: "480p · 1.5 Mbps"
        }
    }

    /// Short form for a label next to the level in force.
    public var shortTitle: String {
        switch self {
        case .auto: "Auto"
        case .original: "Original"
        case .mbps40: "4K"
        case .mbps30: "1440p"
        case .mbps20: "1080p 20"
        case .mbps10: "1080p 10"
        case .mbps4: "720p"
        case .mbps1_5: "480p"
        }
    }

    public var detail: String? {
        switch self {
        case .auto: "Original quality, lowered if the stream can't keep up"
        case .original: "Original quality, never lowered"
        default: nil
        }
    }

    /// Whether a source at `sourceBitrate` needs this level's transcode at
    /// all: a cap above the file's own bitrate would only cost a server
    /// encode for the same picture.
    public func caps(sourceBitrate: Int?) -> Bool {
        guard let maxBitrate else { return false }
        guard let sourceBitrate, sourceBitrate > 0 else { return true }
        return sourceBitrate > maxBitrate
    }

    /// The capped level a stream URL was built at (its
    /// `MaxStreamingBitrate`), or nil for the original. Read off the URL so
    /// it stays true through renewed play sessions and restored windows.
    public static func level(ofStream url: URL) -> LibraryStreamQuality? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "MaxStreamingBitrate" })?.value,
            let bitrate = Int(value)
        else { return nil }
        return capped.first { $0.maxBitrate == bitrate }
    }

    /// The highest capped level whose picture is smaller than `height`, at
    /// or below `current` (nil: the original): where a stream whose picture
    /// is too large to convert to 3D in time goes. Nil when nothing lower
    /// would make the picture smaller.
    public static func smallerPicture(than height: Int, from current: LibraryStreamQuality?) -> LibraryStreamQuality? {
        let ceiling = current?.maxBitrate ?? Int.max
        return capped.first { ($0.maxBitrate ?? 0) <= ceiling && ($0.maxHeight ?? 0) < height && $0 != current }
    }

    /// The next level down from what is playing now, or nil at the bottom.
    /// `current` nil is the original, whose own bitrate decides where the
    /// first step lands: a 6 Mbps file steps to 4 Mbps, not to 20.
    public static func stepDown(from current: LibraryStreamQuality?, sourceBitrate: Int?) -> LibraryStreamQuality? {
        let ceiling = current?.maxBitrate ?? sourceBitrate ?? Int.max
        return capped.first { ($0.maxBitrate ?? 0) < ceiling }
    }

    /// The picture class of a `width`×`height` source, as its height in the
    /// usual ladder (2160, 1440, 1080, 720, 480, 360). By either side, so a
    /// 1920×800 scope film is 1080p and a 1080×1920 portrait clip too.
    public static func pictureClass(width: Int, height: Int) -> Int {
        let long = max(width, height)
        let short = min(width, height)
        let ladder: [(long: Int, short: Int, height: Int)] = [
            (3200, 1800, 2160), (2200, 1300, 1440), (1700, 950, 1080), (1100, 650, 720), (700, 420, 480),
        ]
        return ladder.first { long >= $0.long || short >= $0.short }?.height ?? 360
    }

    /// The choices a player offers for a source: Auto and the original, and
    /// each capped level that would actually send something different. A
    /// level whose picture class is above the source's would only send the
    /// source's own picture under that level's name (a 1080p film offered
    /// as "4K"), and one whose cap is above the source's bitrate plays the
    /// original anyway (`caps(sourceBitrate:)`); neither is offered. With the
    /// source's size unknown, every level that caps its bitrate is.
    public static func offered(sourceWidth: Int?, sourceHeight: Int?, sourceBitrate: Int?) -> [LibraryStreamQuality] {
        let sourceClass: Int? = if let sourceWidth, let sourceHeight, sourceWidth > 0, sourceHeight > 0 {
            pictureClass(width: sourceWidth, height: sourceHeight)
        } else {
            nil
        }
        return [.auto, .original] + capped.filter { level in
            guard level.caps(sourceBitrate: sourceBitrate) else { return false }
            guard let sourceClass, let height = level.maxHeight else { return true }
            return height <= sourceClass
        }
    }
}

/// Watches a Library stream for the two ways a too-fast stream shows itself
/// and says when `auto` should step down:
///
/// - **No picture at start.** `startupTimeout` after the player was given the
///   stream, no frame has shown.
/// - **Rebuffering.** The player waiting for data while it means to play,
///   either one wait of `longStall` or `stallBudget` in total over the last
///   `window`. Waits in the `seekGrace` after a seek or stream switch don't
///   count: every player waits there, whatever the link.
///
/// Pure bookkeeping over the times it's told, so it can be tested without a
/// player.
public struct StreamStallMonitor {
    public static let startupTimeout: TimeInterval = 12
    public static let longStall: TimeInterval = 6
    public static let stallBudget: TimeInterval = 10
    public static let window: TimeInterval = 90
    public static let seekGrace: TimeInterval = 4
    /// After a step, the new stream gets this long before another.
    public static let settleTime: TimeInterval = 15

    public init() {}

    private var stallStart: Date?
    private var finishedStalls: [(end: Date, length: TimeInterval)] = []
    private var graceUntil: Date = .distantPast
    private var lastStep: Date = .distantPast

    /// A seek, a new stream, a pause: waits right after it are expected.
    public mutating func restartGrace(at now: Date) {
        graceUntil = now.addingTimeInterval(Self.seekGrace)
        stallStart = nil
    }

    public mutating func noteStepped(at now: Date) {
        lastStep = now
        finishedStalls = []
        restartGrace(at: now)
    }

    /// The player's waiting state at `now`. Returns true when the stream
    /// should step down.
    public mutating func update(waiting: Bool, at now: Date) -> Bool {
        guard now >= graceUntil else {
            stallStart = nil
            return false
        }
        if waiting {
            if stallStart == nil { stallStart = now }
        } else if let start = stallStart {
            finishedStalls.append((now, now.timeIntervalSince(start)))
            stallStart = nil
        }
        finishedStalls.removeAll { now.timeIntervalSince($0.end) > Self.window }
        guard now.timeIntervalSince(lastStep) >= Self.settleTime else { return false }
        let current = stallStart.map { now.timeIntervalSince($0) } ?? 0
        let total = finishedStalls.reduce(current) { $0 + $1.length }
        return current >= Self.longStall || total >= Self.stallBudget
    }
}
