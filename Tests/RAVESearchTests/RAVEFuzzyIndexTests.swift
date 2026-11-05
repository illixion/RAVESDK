import Foundation
import Testing
@testable import RAVESearch

/// Worldcast ranks podcast episodes with its own copy of this matcher, kept in step with its backend's JS
/// (`Worldcast/EpisodeSearchTests.swift`). These are the same fixtures and the same expected orders and scores,
/// run through the generic index with Worldcast's configuration: if they hold, Worldcast can adopt this index
/// without a ranking change.
struct WorldcastParityTests {
    private let ids = Array(1...5)

    private var index: RAVEFuzzyIndex<Int> {
        // Title weighs 3, description 1; equal scores list the newer episode first.
        func doc(_ id: Int, _ title: String, _ description: String, _ pub: Int) -> RAVEFuzzyDocument<Int> {
            RAVEFuzzyDocument(id: id, fields: [title, RAVEFuzzyText.plainText(description)], priority: -pub)
        }
        return RAVEFuzzyIndex(weights: [3, 1], documents: [
            doc(1, "Mechanical Disadvantage", "<p>Talk about levers &amp; pulleys</p>", 10),
            doc(2, "Technical Countermeasures", "A DIY mechanical keyboard build", 20),
            doc(3, "Morale-Sucking Maple Syrup Fires", "Nothing else", 30),
            doc(4, "Too Much Apple in My Apple", "Café culture and the podcasting life", 40),
            doc(5, "The Structure of a Podcast", "Episode notes", 50),
        ])
    }

    private func ranked(_ query: String) -> String {
        index.search(query).map { "\($0.id):\(String(format: "%.2f", $0.score))" }.joined(separator: " ")
    }

    @Test(arguments: [
        ("mechanical", "1:3.00 2:1.00"),
        ("mechancal disadvantge", "1:3.60"),
        ("aple", "4:1.80 3:1.80"),
        ("podcsat", "5:1.80 4:0.40"),
        ("cafe", "4:1.00"),
        ("CAFÉ", "4:1.00"),
        ("keyboard mechanical", "2:2.00"),
        ("zzz", ""),
        ("", ""),
        ("pulley", "1:0.80"),
    ])
    func matchesWorldcastRanking(query: String, expected: String) {
        #expect(ranked(query) == expected)
    }

    @Test func snippetBoldsMatchedWords() throws {
        let matched = index.searchWithMatches("keybord").matched
        let s = try #require(RAVEFuzzyText.snippet("A DIY mechanical keyboard build", matched: matched, radius: 10))
        #expect(String(s.characters) == "…keyboard build")
        #if !os(Linux)
        let bold = s.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(s[$0.range].characters) }
        #expect(bold == ["keyboard"])
        #endif
    }

    @Test func htmlIsStrippedAndEntitiesDecoded() {
        #expect(RAVEFuzzyText.plainText("<b>A</b> &amp; B&#39;s &#x41;") == "A & B's A")
    }
}

/// Hypnos's music library: three fields, kinds ranked on ties, titles preferred, names closed up.
struct CatalogueConfigurationTests {
    enum Kind: Int { case artist, album, song }

    private func index() -> RAVEFuzzyIndex<String> {
        func doc(_ id: String, _ kind: Kind, _ name: String, _ artist: String = "", _ album: String = "") -> RAVEFuzzyDocument<String> {
            RAVEFuzzyDocument(id: id, fields: [name, artist, album], priority: kind.rawValue * 1000 + min(name.count, 999))
        }
        return RAVEFuzzyIndex(
            weights: [3, 1.5, 1],
            documents: [
                doc("ar1", .artist, "The Beatles"), doc("ar2", .artist, "Motörhead"), doc("ar3", .artist, "AC/DC"),
                doc("al1", .album, "Abbey Road", "The Beatles"), doc("al2", .album, "Ace of Spades", "Motörhead"),
                doc("s1", .song, "Come Together", "The Beatles", "Abbey Road"),
                doc("s2", .song, "Ace of Spades", "Motörhead", "Ace of Spades"),
                doc("s5", .song, "Sgt. Pepper's Lonely Hearts Club Band", "The Beatles", "Sgt. Pepper's Lonely Hearts Club Band"),
            ],
            options: RAVEFuzzyOptions(primaryExactBonus: 6, primaryPrefixBonus: 3, joinPrimaryWords: true))
    }

    private func top(_ query: String) -> [String] { index().search(query).map(\.id) }

    @Test func typosDiacriticsAndClosedUpNames() {
        #expect(top("beatels").first == "ar1")
        #expect(top("motorhed").first == "ar2")
        #expect(top("acdc").first == "ar3")
        #expect(top("ac dc").first == "ar3")
    }

    @Test func aTitleOutranksItsTracksAndArtistsListFirstOnATie() {
        #expect(top("abbey road").first == "al1")
        #expect(top("ace of spades").prefix(2).sorted() == ["al2", "s2"])
        #expect(top("beatles").first == "ar1")
    }

    @Test func everyWordMustMatchAcrossFields() {
        #expect(top("come tog").first == "s1")
        #expect(top("peper lonely").first == "s5")
        #expect(top("beatles abbey").first == "al1")
        #expect(top("beatles motorhead").isEmpty)
    }
}

struct RAVEFuzzyIndexBehaviourTests {
    @Test func emptyCorpusAndEmptyQueryFindNothing() {
        #expect(RAVEFuzzyIndex<Int>(weights: [1], documents: []).search("a").isEmpty)
        let index = RAVEFuzzyIndex(weights: [1], documents: [RAVEFuzzyDocument(id: 1, fields: ["hello"])])
        #expect(index.search("").isEmpty && index.search("   ").isEmpty && index.search("--").isEmpty)
    }

    @Test func missingFieldsCountAsEmpty() {
        let index = RAVEFuzzyIndex(weights: [2, 1], documents: [RAVEFuzzyDocument(id: "a", fields: ["only title"])])
        #expect(index.search("title").map(\.id) == ["a"])
    }

    @Test func limitCapsTheHitsAndInputOrderBreaksTiesAfterPriority() {
        let documents = (0..<10).map { RAVEFuzzyDocument(id: $0, fields: ["same"], priority: $0 < 5 ? 1 : 0) }
        let index = RAVEFuzzyIndex(weights: [1], documents: documents)
        #expect(index.search("same", limit: 3).map(\.id) == [5, 6, 7])
        #expect(index.search("same").map(\.id) == [5, 6, 7, 8, 9, 0, 1, 2, 3, 4])
    }

    @Test func aSwapOfNeighboursIsOneTypo() {
        let a = Array("ab".unicodeScalars), b = Array("ba".unicodeScalars)
        #expect(RAVEFuzzyIndex<Int>.editDistance(a, b[...], limit: 2) == 1)
        #expect(RAVEFuzzyIndex<Int>.editDistance(Array("abcdef".unicodeScalars), Array("xyz".unicodeScalars)[...], limit: 1) == 2)
    }

    @Test func shortWordsGetNoTypoMatching() {
        let index = RAVEFuzzyIndex(weights: [1], documents: [RAVEFuzzyDocument(id: 1, fields: ["cat"])])
        #expect(index.search("cut").isEmpty)
        #expect(index.search("ca").map(\.id) == [1], "A two-letter prefix still matches")
    }

    @Test func aBigCorpusSearchesAndTheIdTypeIsFree() {
        let words = ["love", "night", "fire", "blue", "heart", "road", "dream", "stone", "river", "shadow"]
        let documents = (0..<5000).map { n in
            RAVEFuzzyDocument(id: UUID(), fields: ["\(words[n % 10]) \(words[(n / 10) % 10]) \(n)"])
        }
        let index = RAVEFuzzyIndex(weights: [1], documents: documents)
        #expect(index.count == 5000)
        #expect(index.search("shadow river").count == 100)
        #expect(index.search("shadw rver 42").first != nil)
    }
}
