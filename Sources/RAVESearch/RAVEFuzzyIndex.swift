import Foundation

// A typo-tolerant, weighted search over a few text fields per item, held in memory.
//
// Lifted from two apps that wrote it twice: Worldcast ranks podcast episodes by title and description (a port of
// its backend's fuzzy.js), and Hypnos ranks a music library by name, artist and album. What they share is here;
// what differs is configuration (`RAVEFuzzyOptions`) and the tie-break (`priority`).
//
// Every word of the query must match a word of the item, and each is matched in tiers: exact, prefix, one typo,
// substring, two typos ("beatels", "sgt pep" and "motorhed" all find what is meant). Each query word is resolved
// once against the corpus's vocabulary to the words it matches (with a score); items are then scored by lookup,
// so typo matching costs vocabulary size, not text length, and an inverted word -> items list keeps a library of
// tens of thousands of items to a few milliseconds a search.
//
// Foundation only: it builds on every platform, Linux included.

/// What an index is configured with. The defaults reproduce Worldcast's ranking, which is pinned by its parity
/// tests (`RAVEFuzzyIndexTests.worldcastParity`).
public struct RAVEFuzzyOptions: Sendable, Equatable {
    /// Added once when a query of two or more words appears, in order, in the primary field.
    public var phraseBonus = 2.0
    /// Added when the query is all of the primary field ("abbey road" for the title "Abbey Road"), or the start
    /// of it. Zero by default: a corpus of long text wants no such preference; a catalogue of titles does.
    public var primaryExactBonus = 0.0
    public var primaryPrefixBonus = 0.0
    /// Also index the primary field's words closed up as one word, so "acdc" finds "AC/DC" and "pnk" finds "P!nk".
    public var joinPrimaryWords = false
    /// Longest closed-up word; a long title closed up matches nothing anyone types.
    public var maxJoinedLength = 24
    /// Vocabulary words longer than this get no typo matching (the edit distance isn't worth computing).
    public var maxTypoWordLength = 40

    public init(phraseBonus: Double = 2, primaryExactBonus: Double = 0, primaryPrefixBonus: Double = 0,
                joinPrimaryWords: Bool = false, maxJoinedLength: Int = 24, maxTypoWordLength: Int = 40) {
        self.phraseBonus = phraseBonus
        self.primaryExactBonus = primaryExactBonus
        self.primaryPrefixBonus = primaryPrefixBonus
        self.joinPrimaryWords = joinPrimaryWords
        self.maxJoinedLength = maxJoinedLength
        self.maxTypoWordLength = maxTypoWordLength
    }
}

/// One item to index. `fields` line up with the index's weights; the first is the primary field (a title, a name).
public struct RAVEFuzzyDocument<ID: Hashable & Sendable>: Sendable {
    public var id: ID
    public var fields: [String]
    /// Among items of equal score, the lower priority comes first, then the one given first. A newest-first list
    /// uses the negated date; a catalogue that wants artists before albums before songs uses the kind's rank.
    public var priority: Int

    public init(id: ID, fields: [String], priority: Int = 0) {
        self.id = id
        self.fields = fields
        self.priority = priority
    }
}

public struct RAVEFuzzyHit<ID: Hashable & Sendable>: Sendable {
    public let id: ID
    public let score: Double
}

public struct RAVEFuzzyIndex<ID: Hashable & Sendable>: Sendable {
    private struct Entry: Sendable {
        let id: ID
        let priority: Int
        let order: Int
        /// The primary field as folded words joined by spaces, for the title bonuses.
        let primaryText: String
        /// Per field, the vocabulary words it holds.
        let words: [[Int32]]
    }

    public let weights: [Double]
    public let options: RAVEFuzzyOptions
    private let entries: [Entry]
    private let vocabulary: [(word: String, scalars: [Unicode.Scalar])]
    /// For each vocabulary word, the entries that contain it in any field.
    private let postings: [[Int32]]

    public var count: Int { entries.count }

    /// - Parameter weights: how much a match in each field counts, in the order of `RAVEFuzzyDocument.fields`
    ///   (Worldcast: title 3, description 1; Hypnos: name 3, artist 1.5, album 1). A match scores its tier
    ///   (0.3 to 1) times the weight of the best field it is in.
    public init(weights: [Double], documents: [RAVEFuzzyDocument<ID>], options: RAVEFuzzyOptions = RAVEFuzzyOptions()) {
        precondition(!weights.isEmpty, "an index needs at least one field")
        self.weights = weights
        self.options = options
        var ids: [String: Int32] = [:]
        var words: [String] = []
        func intern(_ list: [String]) -> [Int32] {
            var out: [Int32] = []
            for word in list {
                let id: Int32
                if let known = ids[word] { id = known } else {
                    id = Int32(words.count); ids[word] = id; words.append(word)
                }
                if !out.contains(id) { out.append(id) }
            }
            return out
        }
        var built: [Entry] = []
        built.reserveCapacity(documents.count)
        for (order, document) in documents.enumerated() {
            var perField: [[Int32]] = []
            var primaryText = ""
            for field in weights.indices {
                let list = RAVEFuzzyText.words(field < document.fields.count ? document.fields[field] : "")
                var tokens = list
                if field == 0 {
                    primaryText = list.joined(separator: " ")
                    // "AC/DC" is also typed "acdc": the primary field with its punctuation closed up is a word too.
                    if options.joinPrimaryWords, list.count > 1 {
                        let joined = list.joined()
                        if joined.count <= options.maxJoinedLength { tokens.append(joined) }
                    }
                }
                perField.append(intern(tokens))
            }
            built.append(Entry(id: document.id, priority: document.priority, order: order,
                               primaryText: primaryText, words: perField))
        }
        var lists = [[Int32]](repeating: [], count: words.count)
        for (index, entry) in built.enumerated() {
            for word in Set(entry.words.flatMap { $0 }) { lists[Int(word)].append(Int32(index)) }
        }
        entries = built
        vocabulary = words.map { ($0, Array($0.unicodeScalars)) }
        postings = lists
    }

    /// Every word of `query` must match a word of an item. Best first.
    public func search(_ query: String, limit: Int = 100) -> [RAVEFuzzyHit<ID>] {
        searchWithMatches(query, limit: limit).hits
    }

    /// `search`, plus every vocabulary word any query word matched, for `RAVEFuzzyText.snippet` to highlight.
    public func searchWithMatches(_ query: String, limit: Int = 100) -> (hits: [RAVEFuzzyHit<ID>], matched: Set<String>) {
        var seen = Set<String>()
        let terms = RAVEFuzzyText.words(query).filter { seen.insert($0).inserted }
        guard !terms.isEmpty, !entries.isEmpty else { return ([], []) }

        // Resolve each term against the vocabulary once; items are then scored by lookup.
        var matches: [[Int32: Double]] = []
        for term in terms {
            let scalars = Array(term.unicodeScalars)
            var matched: [Int32: Double] = [:]
            for (index, word) in vocabulary.enumerated() {
                let score = Self.termMatch(scalars, word.scalars, word: word.word, term: term, maxTypoWordLength: options.maxTypoWordLength)
                if score > 0 { matched[Int32(index)] = score }
            }
            if matched.isEmpty { return ([], []) }
            matches.append(matched)
        }

        // Candidates: the items that hold a match of every term, found through the postings.
        var candidates: Set<Int32>?
        for matched in matches.sorted(by: { $0.count < $1.count }) {
            var found = Set<Int32>()
            for word in matched.keys { found.formUnion(postings[Int(word)]) }
            candidates = candidates.map { $0.intersection(found) } ?? found
            if candidates?.isEmpty == true { return ([], []) }
        }

        let phrase = terms.joined(separator: " ")
        var scored: [(hit: RAVEFuzzyHit<ID>, priority: Int, order: Int)] = []
        for index in candidates ?? [] {
            let entry = entries[Int(index)]
            var total = 0.0
            var ok = true
            for matched in matches {
                var best = 0.0
                for (field, words) in entry.words.enumerated() {
                    for word in words { if let score = matched[word] { best = max(best, score * weights[field]) } }
                }
                if best == 0 { ok = false; break }
                total += best
            }
            guard ok else { continue }
            if options.primaryExactBonus > 0, entry.primaryText == phrase { total += options.primaryExactBonus }
            else if options.primaryPrefixBonus > 0, entry.primaryText.hasPrefix(phrase) { total += options.primaryPrefixBonus }
            else if terms.count > 1, entry.primaryText.contains(phrase) { total += options.phraseBonus }
            scored.append((RAVEFuzzyHit(id: entry.id, score: total), entry.priority, entry.order))
        }
        scored.sort {
            if $0.hit.score != $1.hit.score { return $0.hit.score > $1.hit.score }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.order < $1.order
        }
        var matched = Set<String>()
        for terms in matches { for word in terms.keys { matched.insert(vocabulary[Int(word)].word) } }
        return (scored.prefix(limit).map(\.hit), matched)
    }

    // MARK: - Matching

    /// How well `term` matches vocabulary word `word`: 0 (no match) to 1 (exact). A one-typo word outranks a mere
    /// substring ("aple" -> "apple" over "maple"), but a two-typo word stays below an exact word in a lesser field.
    static func termMatch(_ term: [Unicode.Scalar], _ other: [Unicode.Scalar], word: String, term text: String,
                          maxTypoWordLength: Int = 40) -> Double {
        if word == text { return 1 }
        let length = term.count
        if length >= 2, word.hasPrefix(text) { return 0.8 }
        let maxEdits = length >= 8 ? 2 : length >= 4 ? 1 : 0
        let typoOk = maxEdits > 0 && other.count <= maxTypoWordLength
        let distance = typoOk ? editDistance(term, other[...], limit: maxEdits) : Int.max
        if distance == 1 { return 0.6 }
        if length >= 3, word.contains(text) { return 0.5 }
        if distance == 2, maxEdits == 2 { return 0.3 }
        // A half-typed word with a typo ("podcsat" -> "podcasting"). Only from five letters on; shorter prefixes
        // with a typo match nearly anything.
        if typoOk, length >= 5, other.count > length,
           editDistance(term, other[..<length], limit: maxEdits) <= maxEdits { return 0.4 }
        return 0
    }

    /// Optimal-string-alignment distance (a swap of neighbours costs one), or `limit + 1` once it must exceed `limit`.
    static func editDistance(_ a: [Unicode.Scalar], _ bSlice: ArraySlice<Unicode.Scalar>, limit: Int) -> Int {
        let b = Array(bSlice)
        if abs(a.count - b.count) > limit { return limit + 1 }
        let n = b.count
        var previous2: [Int] = []
        var previous = Array(0...n)
        var current = [Int](repeating: 0, count: n + 1)
        for i in stride(from: 1, through: a.count, by: 1) {
            current[0] = i
            var rowMinimum = i
            for j in stride(from: 1, through: n, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if !previous2.isEmpty, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                if value < rowMinimum { rowMinimum = value }
            }
            if rowMinimum > limit { return limit + 1 }
            previous2 = previous
            previous = current
        }
        return previous[n]
    }
}
