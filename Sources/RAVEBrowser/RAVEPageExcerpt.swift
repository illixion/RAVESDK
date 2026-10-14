//
//  RAVEPageExcerpt.swift
//  RAVEBrowser
//
//  The part of a long page worth giving a model for one question. A page
//  often runs far past what fits in a prompt, and the answer is rarely in its
//  opening: Wikipedia's red fox gives its lifespan far below the first
//  screenful a prompt has room for. So the excerpt is the page's opening (what it is about)
//  plus the paragraphs that share the most words with the question, kept in
//  page order and marked where text was left out.
//
//  Words match on their first five letters, which is crude stemming that
//  needs no language model: "weighs" finds "weight", "habitats" finds
//  "habitat". Nothing here knows any site, or any language beyond a short
//  list of English words too common to count.
//

import Foundation

public enum RAVEPageExcerpt {
    /// `text` if it fits in `budget` characters; otherwise its first
    /// `opening` characters and the paragraphs that best match `question`.
    public static func select(_ text: String, question: String, budget: Int,
                              opening: Int = 3000) -> String {
        guard text.count > budget else { return text }
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let terms = Set(stems(question))

        // The opening: whole paragraphs up to `opening` characters.
        var chosen = Set<Int>()
        var used = 0
        for (index, paragraph) in paragraphs.enumerated() {
            guard used + paragraph.count <= opening || chosen.isEmpty else { break }
            chosen.insert(index)
            used += paragraph.count + 2
        }

        // Then the best matches, scored by how many of the question's words
        // they share; a heading carries its section, so it is kept with the
        // paragraph after it.
        if !terms.isEmpty {
            let scored = paragraphs.enumerated().compactMap { index, paragraph -> (Int, Int)? in
                guard !chosen.contains(index) else { return nil }
                let score = Set(stems(paragraph)).intersection(terms).count
                return score > 0 ? (index, score) : nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            for (index, _) in scored {
                let paragraph = paragraphs[index]
                guard used + paragraph.count + 2 <= budget else { continue }
                chosen.insert(index)
                used += paragraph.count + 2
                if index > 0, paragraphs[index - 1].hasPrefix("#"), !chosen.contains(index - 1),
                   used + paragraphs[index - 1].count + 2 <= budget {
                    chosen.insert(index - 1)
                    used += paragraphs[index - 1].count + 2
                }
            }
        }

        var pieces: [String] = []
        var previous = -1
        for index in chosen.sorted() {
            if previous >= 0, index != previous + 1 { pieces.append("[…]") }
            pieces.append(paragraphs[index])
            previous = index
        }
        if previous < paragraphs.count - 1 { pieces.append("[…]") }
        return pieces.joined(separator: "\n\n")
    }

    /// Lowercased words of three letters or more, cut to five letters, minus
    /// the commonest English words.
    static func stems(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 3 }
            .map { String($0.prefix(5)) }
            .filter { !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "her", "was", "one", "our",
        "out", "has", "his", "how", "its", "who", "did", "get", "may", "him", "she", "too", "use", "they",
        "them", "then", "than", "that", "this", "these", "those", "there", "their", "what", "when", "where",
        "which", "while", "with", "would", "could", "shoul", "about", "does", "doing", "have", "from",
        "into", "page", "tell", "some", "much", "many", "will", "were", "been", "being", "also", "more",
    ]
}
