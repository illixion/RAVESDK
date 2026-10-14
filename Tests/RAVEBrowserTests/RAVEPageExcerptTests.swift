import Testing
@testable import RAVEBrowser

@Suite struct RAVEPageExcerptTests {
    static let filler = String(repeating: "Foxes are small omnivores of the family Canidae. ", count: 20)

    static let page = (["# Red fox", "The red fox is the largest of the true foxes."]
        + (1...30).map { "## Section \($0)\n\n\(filler)" }
        + ["## Lifespan", "Red foxes live up to 15 years in captivity, but rarely past 5 years in the wild."]
        + (31...40).map { "## Section \($0)\n\n\(filler)" })
        .joined(separator: "\n\n")

    @Test func aShortPageIsGivenWhole() {
        #expect(RAVEPageExcerpt.select("Short page.", question: "anything", budget: 100) == "Short page.")
    }

    @Test func keepsTheOpeningAndFindsTheAnswerFarDown() {
        let excerpt = RAVEPageExcerpt.select(Self.page, question: "How long do they live in the wild?",
                                             budget: 3000, opening: 500)
        #expect(excerpt.count <= 3200)
        #expect(excerpt.hasPrefix("# Red fox"))
        #expect(excerpt.contains("rarely past 5 years in the wild"))
        // Its heading comes with it, and the gaps are marked.
        #expect(excerpt.contains("## Lifespan\n\nRed foxes live"))
        #expect(excerpt.contains("[…]"))
    }

    @Test func stemsMatchWordForms() {
        #expect(RAVEPageExcerpt.stems("Living lives") == ["livin", "lives"])
        #expect(RAVEPageExcerpt.stems("How does the page say it?") == ["say"])
    }
}
