/*
 RAVE SDK — subtitles: a text track parsed once, looked up by time, and
 drawn over a picture.

 The players that need this own their pictures (an AVSampleBufferDisplayLayer
 on a host-clock timebase, a stereo warp, a RealityKit video material), so
 there is no AVPlayerItem whose legible output could draw them. The host
 fetches a WebVTT or SubRip file, parses it here, and hands
 `RAVESubtitleOverlay` the same clock its picture runs on.

 Parsing is forgiving rather than strict. Media servers emit slightly
 different dialects: Jellyfin's converted WebVTT, a sidecar SRT carrying
 `<font>` tags or ASS override blocks (`{\an8}`), cue settings after the
 timestamps. Styling is reduced to italic and bold, which subtitles use for
 meaning (off-screen voices, emphasis); everything else is dropped. A cue
 asking for the top of the frame (`{\an8}`, WebVTT `line:0`) is placed
 there, since that is how subtitles get out of the way of burned-in text.
 */

import Foundation

public struct RAVESubtitleCue: Equatable, Sendable {
    public enum Placement: Equatable, Sendable { case bottom, top }

    public var start: Double
    public var end: Double
    /// Italic and bold as inline presentation intents; lines separated by "\n".
    public var text: AttributedString
    public var placement: Placement

    public init(start: Double, end: Double, text: AttributedString, placement: Placement = .bottom) {
        self.start = start
        self.end = end
        self.text = text
        self.placement = placement
    }

    public var plainText: String { String(text.characters) }
}

public enum RAVESubtitleError: Error, LocalizedError {
    case unreadable
    case noCues

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The subtitle file isn't text."
        case .noCues: "The subtitle file has no cues."
        }
    }
}

public struct RAVESubtitleTrack: Equatable, Sendable {
    /// Distinguishes two loads of the same file, so a view keyed on the track
    /// restarts its clock.
    public let id = UUID()
    /// Sorted by start time.
    public let cues: [RAVESubtitleCue]
    /// The longest cue, which bounds how far back a lookup has to look for a
    /// cue that started earlier and is still showing.
    private let longestCue: Double

    public init(cues: [RAVESubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
        longestCue = cues.map { $0.end - $0.start }.max() ?? 0
    }

    /// Parses WebVTT or SubRip, decided by the WebVTT header.
    public init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252) else { throw RAVESubtitleError.unreadable }
        try self.init(text: text)
    }

    public init(text: String) throws {
        let cues = RAVESubtitleParser.parse(text)
        guard !cues.isEmpty else { throw RAVESubtitleError.noCues }
        self.init(cues: cues)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// The cues showing at `time`, in start order.
    public func cues(at time: Double) -> [RAVESubtitleCue] {
        // First cue starting after `time`.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var showing: [RAVESubtitleCue] = []
        var index = low - 1
        while index >= 0, cues[index].start >= time - longestCue {
            if cues[index].end > time { showing.append(cues[index]) }
            index -= 1
        }
        return showing.reversed()
    }
}

enum RAVESubtitleParser {
    static func parse(_ source: String) -> [RAVESubtitleCue] {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let isWebVTT = text.hasPrefix("WEBVTT")

        var cues: [RAVESubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // The timing line follows an optional identifier (SRT's counter,
            // a WebVTT cue id). NOTE/STYLE/REGION blocks and the header have none.
            guard let timingIndex = lines.prefix(2).firstIndex(where: { $0.contains("-->") }),
                  let timing = parseTiming(lines[timingIndex]) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            var placement = timing.settings.flatMap(webVTTPlacement) ?? .bottom
            if !isWebVTT || body.contains("{\\") {
                placement = assPlacement(in: body) ?? placement
            }
            let styled = styledText(body)
            guard timing.end > timing.start, !styled.characters.isEmpty else { continue }
            cues.append(RAVESubtitleCue(start: timing.start, end: timing.end, text: styled, placement: placement))
        }
        return cues
    }

    // MARK: Timing

    private static func parseTiming(_ line: String) -> (start: Double, end: Double, settings: String?)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let endFields = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard let start = timestamp(parts[0].trimmingCharacters(in: .whitespaces)),
              let endField = endFields.first, let end = timestamp(String(endField)) else { return nil }
        return (start, end, endFields.count > 1 ? String(endFields[1]) : nil)
    }

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm` or `MM:SS.mmm`.
    static func timestamp(_ value: String) -> Double? {
        let fields = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count), let seconds = Double(fields.last!) else { return nil }
        var total = seconds
        var multiplier = 60.0
        for field in fields.dropLast().reversed() {
            guard let number = Double(field) else { return nil }
            total += number * multiplier
            multiplier *= 60
        }
        return total
    }

    /// WebVTT's `line:` setting. A non-negative line number counts from the
    /// top; a percentage is a position down the frame.
    private static func webVTTPlacement(_ settings: String) -> RAVESubtitleCue.Placement? {
        for setting in settings.split(separator: " ") where setting.hasPrefix("line:") {
            let value = setting.dropFirst(5).split(separator: ",").first.map(String.init) ?? ""
            if value.hasSuffix("%"), let percent = Double(value.dropLast()) {
                return percent < 50 ? .top : .bottom
            }
            if let line = Int(value) { return line >= 0 ? .top : .bottom }
        }
        return nil
    }

    /// ASS alignment override: `\an7`–`\an9` are the top row.
    private static func assPlacement(in body: String) -> RAVESubtitleCue.Placement? {
        guard let range = body.range(of: #"\\an([1-9])"#, options: .regularExpression),
              let digit = body[range].last?.wholeNumberValue else { return nil }
        return digit >= 7 ? .top : .bottom
    }

    // MARK: Text

    private static let entities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", "\u{00A0}"), ("&quot;", "\""), ("&#39;", "'"),
        ("&apos;", "'"), ("&lrm;", "\u{200E}"), ("&rlm;", "\u{200F}"), ("&amp;", "&"),
    ]

    /// Italic and bold survive; other tags, ASS override blocks and blank
    /// lines don't.
    static func styledText(_ body: String) -> AttributedString {
        var source = body
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: "\u{00A0}")
        source = source.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        var result = AttributedString()
        var italic = 0, bold = 0
        var rest = Substring(source)
        while !rest.isEmpty {
            guard let open = rest.firstIndex(of: "<") else {
                result += run(rest, italic: italic > 0, bold: bold > 0)
                break
            }
            result += run(rest[..<open], italic: italic > 0, bold: bold > 0)
            guard let close = rest[open...].firstIndex(of: ">") else {
                // A lone "<" is text.
                result += run(rest[open...], italic: italic > 0, bold: bold > 0)
                break
            }
            let tag = rest[rest.index(after: open)..<close].lowercased()
            switch tag {
            case "i": italic += 1
            case "/i": italic = max(0, italic - 1)
            case "b": bold += 1
            case "/b": bold = max(0, bold - 1)
            default: break
            }
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    private static func run(_ text: Substring, italic: Bool, bold: Bool) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        var decoded = String(text)
        if decoded.contains("&") {
            for (entity, character) in entities { decoded = decoded.replacingOccurrences(of: entity, with: character) }
        }
        var run = AttributedString(decoded)
        var intent: InlinePresentationIntent = []
        if italic { intent.insert(.emphasized) }
        if bold { intent.insert(.stronglyEmphasized) }
        if !intent.isEmpty { run.inlinePresentationIntent = intent }
        return run
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// The cues of `track` showing on the host's clock, handed to `content`.
///
/// `time` is sampled about 20 times a second and should return the film time
/// of the frame being shown; `content` re-renders only when the set changes.
public struct RAVESubtitleCues<Content: View>: View {
    private let track: RAVESubtitleTrack?
    private let time: @MainActor () -> Double
    private let content: ([RAVESubtitleCue]) -> Content
    @State private var showing: [RAVESubtitleCue] = []

    public init(track: RAVESubtitleTrack?, time: @escaping @MainActor () -> Double,
                @ViewBuilder content: @escaping ([RAVESubtitleCue]) -> Content) {
        self.track = track
        self.time = time
        self.content = content
    }

    public var body: some View {
        content(showing)
            .task(id: track?.id) {
                guard let track else {
                    showing = []
                    return
                }
                while !Task.isCancelled {
                    let current = track.cues(at: time())
                    if current != showing { showing = current }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
    }
}

/// Draws a subtitle track over a picture, following the host's clock.
///
/// `pictureAspect` (width / height) places the text inside an aspect-fitted
/// picture rather than in a letterbox bar; leave it nil when the view is the
/// picture's own size. Never takes hits.
public struct RAVESubtitleOverlay: View {
    private let track: RAVESubtitleTrack?
    private let pictureAspect: CGFloat?
    private let time: @MainActor () -> Double

    public init(track: RAVESubtitleTrack?, pictureAspect: CGFloat? = nil, time: @escaping @MainActor () -> Double) {
        self.track = track
        self.pictureAspect = pictureAspect
        self.time = time
    }

    public var body: some View {
        GeometryReader { geometry in
            let picture = Self.fittedRect(in: geometry.size, aspect: pictureAspect)
            let fontSize = Self.fontSize(forPictureHeight: picture.height)
            RAVESubtitleCues(track: track, time: time) { showing in
                VStack(spacing: 0) {
                    block(showing.filter { $0.placement == .top }, fontSize: fontSize)
                    Spacer(minLength: 0)
                    block(showing.filter { $0.placement == .bottom }, fontSize: fontSize)
                }
                .padding(.vertical, picture.height * 0.05)
                .frame(width: picture.width, height: picture.height)
                .position(x: picture.midX, y: picture.midY)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func block(_ cues: [RAVESubtitleCue], fontSize: CGFloat) -> some View {
        if !cues.isEmpty {
            RAVESubtitleText(cues: cues, fontSize: fontSize)
        }
    }

    /// About a twentieth of the picture's height: 36 pt in a 720 pt visionOS
    /// window, 54 pt on a 1080 pt TV, 19 pt across a landscape phone.
    static func fontSize(forPictureHeight height: CGFloat) -> CGFloat {
        min(max(height * 0.05, 15), 64)
    }

    static func fittedRect(in size: CGSize, aspect: CGFloat?) -> CGRect {
        guard let aspect, aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}

/// Subtitles on a panel of their own rather than over the picture: for a
/// stereo picture, where text drawn over it would have to win a depth
/// contest with the scene. Every cue is shown in start order whatever its
/// placement, and the panel keeps room for `reservedLines` so it doesn't
/// jump in size as cues come and go.
public struct RAVESubtitlePanel: View {
    private let track: RAVESubtitleTrack?
    private let fontSize: CGFloat
    private let reservedLines: Int
    private let time: @MainActor () -> Double

    public init(track: RAVESubtitleTrack?, fontSize: CGFloat = 30, reservedLines: Int = 2,
                time: @escaping @MainActor () -> Double) {
        self.track = track
        self.fontSize = fontSize
        self.reservedLines = reservedLines
        self.time = time
    }

    public var body: some View {
        RAVESubtitleCues(track: track, time: time) { showing in
            ZStack(alignment: .top) {
                if !showing.isEmpty {
                    RAVESubtitleText(cues: showing, fontSize: fontSize)
                }
            }
            .frame(maxWidth: .infinity, minHeight: CGFloat(reservedLines) * fontSize * 1.45, alignment: .top)
        }
        .allowsHitTesting(false)
    }
}

/// One group of simultaneous cues, styled the way subtitles are on Apple
/// players: white on a translucent black plate.
public struct RAVESubtitleText: View {
    private let cues: [RAVESubtitleCue]
    private let fontSize: CGFloat

    public init(cues: [RAVESubtitleCue], fontSize: CGFloat) {
        self.cues = cues
        self.fontSize = fontSize
    }

    public var body: some View {
        VStack(spacing: fontSize * 0.15) {
            ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                Text(cue.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, fontSize * 0.4)
                    .padding(.vertical, fontSize * 0.12)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: fontSize * 0.2))
            }
        }
        .padding(.horizontal, fontSize)
        .accessibilityIdentifier("rave.subtitles")
    }
}
#endif
