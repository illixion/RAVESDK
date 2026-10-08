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

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

public struct RAVESubtitleCue: Equatable, Sendable {
    public enum Placement: Equatable, Sendable { case bottom, top }

    public var start: Double
    public var end: Double
    /// Italic and bold as inline presentation intents; lines separated by "\n".
    public var text: AttributedString
    public var placement: Placement
    /// A bitmap subtitle (a disc's PGS) instead of text: drawn where it says,
    /// at its own size relative to the picture.
#if canImport(CoreGraphics)
    public var image: RAVESubtitleImage?
#endif

    public init(start: Double, end: Double, text: AttributedString, placement: Placement = .bottom) {
        self.start = start
        self.end = end
        self.text = text
        self.placement = placement
    }

#if canImport(CoreGraphics)
    /// A bitmap cue; its placement follows which half of the picture it sits in.
    public init(start: Double, end: Double, image: RAVESubtitleImage) {
        self.start = start
        self.end = end
        text = AttributedString()
        placement = image.frame.midY < 0.5 ? .top : .bottom
        self.image = image
    }

#endif

    public var plainText: String { String(text.characters) }
}

#if canImport(CoreGraphics)
/// A subtitle drawn as a picture. The bitmap is made on request rather than
/// held: a film's worth of them at screen size doesn't fit in memory, while
/// their compressed form does.
public struct RAVESubtitleImage: Equatable, Sendable {
    /// Distinguishes captions, so views can cache what `makeImage` gave.
    public let id: Int
    /// Where the image sits in the picture, in fractions of its width and
    /// height, origin top left.
    public let frame: CGRect
    private let make: @Sendable () -> CGImage?

    public init(id: Int, frame: CGRect, make: @escaping @Sendable () -> CGImage?) {
        self.id = id
        self.frame = frame
        self.make = make
    }

    /// The bitmap, premultiplied, sized for the picture the frame is relative
    /// to. Safe off the main thread; costs a decode each call.
    public func makeImage() -> CGImage? { make() }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.frame == rhs.frame }
}

#endif

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
        run[RAVESubtitleEmphasis.self] = (italic ? 1 : 0) | (bold ? 2 : 0)
#if canImport(Darwin)
        var intent: InlinePresentationIntent = []
        if italic { intent.insert(.emphasized) }
        if bold { intent.insert(.stronglyEmphasized) }
        if !intent.isEmpty { run.inlinePresentationIntent = intent }
#endif
        return run
    }
}


/// Portable text styling. Bit 0 is italic, bit 1 bold. Apple renderers also
/// receive Foundation's presentation intents; Android has no such attribute.
public enum RAVESubtitleEmphasis: AttributedStringKey {
    public typealias Value = Int
    public static let name = "rave.subtitle.emphasis"
}
