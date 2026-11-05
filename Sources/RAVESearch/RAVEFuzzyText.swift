import Foundation

/// The text handling under `RAVEFuzzyIndex`, and what a results screen needs to show a match.
///
/// Matching is on **folded words**: case and diacritics gone ("Café" is "cafe"), split on anything that is not a
/// letter or digit. Showing a match is a separate step (`snippet`), which works on the original text.
public enum RAVEFuzzyText {
    /// Fold case, diacritics and width: "Beyoncé" is "beyonce".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Text as folded words. Letters and digits only; everything else splits.
    public static func words(_ text: String) -> [String] {
        fold(text).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    /// HTML as plain text: tags dropped, the common entities decoded, whitespace closed up. For descriptions that
    /// arrive as markup (podcast notes, a server's overview) before they are indexed or excerpted.
    public static func plainText(_ html: String) -> String {
        var out = html.replacing(/<[^>]*>/, with: " ")
        out = out.replacing(/&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);/) { match -> String in
            let entity = String(match.output.1)
            if entity.hasPrefix("#") {
                let hex = entity.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = entity.dropFirst(hex ? 2 : 1)
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    return String(Character(scalar))
                }
                return " "
            }
            return entities[entity.lowercased()] ?? String(match.output.0)
        }
        return out.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A short plain-text excerpt of `text` around its first word in `matched`, with every matched word bold; nil
    /// when none appears (on Linux, whose Foundation has no presentation intents, the excerpt is the same without the
    /// emphasis). `matched` is what `RAVEFuzzyIndex.searchWithMatches` returns.
    public static func snippet(_ text: String?, matched: Set<String>, radius: Int = 70) -> AttributedString? {
        guard let text, !matched.isEmpty else { return nil }
        let plain = plainText(text)
        let wordRanges = plain.ranges(of: /[\p{L}\p{M}\p{N}]+/)
        guard let first = wordRanges.first(where: { matched.contains(fold(String(plain[$0]))) }) else { return nil }

        var start = plain.index(first.lowerBound, offsetBy: -radius, limitedBy: plain.startIndex) ?? plain.startIndex
        var end = plain.index(first.upperBound, offsetBy: radius, limitedBy: plain.endIndex) ?? plain.endIndex
        // Snap to word boundaries so the excerpt doesn't open or close mid-word.
        if start > plain.startIndex, let space = plain[start..<first.lowerBound].firstIndex(of: " ") {
            start = plain.index(after: space)
        }
        if end < plain.endIndex, let space = plain[first.upperBound..<end].lastIndex(of: " ") {
            end = space
        }

        var out = AttributedString(start > plain.startIndex ? "…" : "")
        var cursor = start
        for range in wordRanges where range.lowerBound >= start && range.upperBound <= end {
            guard matched.contains(fold(String(plain[range]))) else { continue }
            out += AttributedString(plain[cursor..<range.lowerBound])
            var bold = AttributedString(plain[range])
            #if !os(Linux)
            bold.inlinePresentationIntent = .stronglyEmphasized
            #endif
            out += bold
            cursor = range.upperBound
        }
        out += AttributedString(plain[cursor..<end])
        if end < plain.endIndex { out += AttributedString("…") }
        return out
    }
}
