import Foundation

/// A skippable stretch reported by a media server, in seconds on the media
/// timeline. Shared as data; hosts decide how to present the skip action.
public struct LibraryMediaSegment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case intro, recap, preview, outro, commercial

        public static func serverType(_ value: String?) -> Kind? {
            switch value {
            case "Intro": .intro
            case "Recap": .recap
            case "Preview": .preview
            case "Outro": .outro
            case "Commercial": .commercial
            default: nil
            }
        }

        public static func chapterName(_ name: String) -> Kind? {
            let words = name.lowercased().split { !$0.isLetter }.map(String.init)
            let text = words.joined(separator: " ")
            func has(_ word: String) -> Bool { words.contains(word) }
            if has("recap") || text.hasPrefix("previously") { return .recap }
            if has("preview") || text.contains("next episode") || text.contains("next time") { return .preview }
            if has("intro") || has("introduction") || has("opening") || has("op")
                || text.contains("title sequence") || text.contains("main titles") { return .intro }
            if has("credits") || has("outro") || has("ending") || has("ed") || has("closing") { return .outro }
            return nil
        }
    }
    public var kind: Kind
    public var startSeconds: Double
    public var endSeconds: Double

    public init(kind: Kind, startSeconds: Double, endSeconds: Double) {
        self.kind = kind
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    /// What the segment is called: "Intro", "Credits".
    public var name: String {
        switch kind {
        case .intro: "Intro"
        case .recap: "Recap"
        case .preview: "Preview"
        case .outro: "Credits"
        case .commercial: "Ad"
        }
    }

    public var skipTitle: String { "Skip \(name)" }
}

/// Common visibility and landing rules for skip-intro/credits controls.
public enum LibrarySegmentSkipPolicy {
    public static let promptSeconds: Double = 8
    public static let minimumLength: Double = 4
    /// How long after a skip it can be undone: long enough to see that a
    /// SponsorBlock segment was marked wrongly, short enough not to linger.
    public static let undoSeconds: Double = 5

    public static func eligible(_ segment: LibraryMediaSegment) -> Bool {
        segment.endSeconds - segment.startSeconds >= minimumLength
    }

    public static func segment(at time: Double, in segments: [LibraryMediaSegment]) -> LibraryMediaSegment? {
        segments.first { time >= $0.startSeconds - 0.25 && time < $0.endSeconds - 1 }
    }

    public static func offered(at time: Double, controlsVisible: Bool,
                               in segments: [LibraryMediaSegment]) -> LibraryMediaSegment? {
        guard let segment = segment(at: time, in: segments) else { return nil }
        return controlsVisible || time < segment.startSeconds + promptSeconds ? segment : nil
    }

    public static func target(for segment: LibraryMediaSegment, duration: Double) -> Double {
        guard duration > 1 else { return segment.endSeconds }
        return min(segment.endSeconds, duration - 0.5)
    }
}
