import Testing
@testable import VideoOrganizer

@Suite("SearchQuery")
struct SearchQueryTests {
    @Test("parses include and exclude terms from raw search text")
    func parsesTerms() {
        let query = SearchQuery("swiftui -ads creator")

        #expect(query.includeTerms == ["swiftui", "creator"])
        #expect(query.excludeTerms == ["ads"])
        #expect(!query.isEmpty)
    }

    @Test("treats whitespace-only text as empty query")
    func emptyQuery() {
        let query = SearchQuery("   ")

        #expect(query.includeTerms.isEmpty)
        #expect(query.excludeTerms.isEmpty)
        #expect(query.isEmpty)
    }

    @Test("matches when all include terms exist and excluded terms do not")
    func matchesFields() {
        let query = SearchQuery("swiftui layout -sponsor")

        #expect(query.matches(fields: ["SwiftUI layout techniques", "No sponsor message here"]) == false)
        #expect(query.matches(fields: ["SwiftUI layout techniques", "Creator notes"]) == true)
    }

    @Test("matches are localized and case-insensitive")
    func localizedMatching() {
        let query = SearchQuery("alpha")

        #expect(query.matches(fields: ["ALPHA Channel"]) == true)
    }

    // MARK: - from: operator

    @Test("parses from:CreatorName operator into fromCreator")
    func parsesFromOperator() {
        let query = SearchQuery("from:Hipyo")
        #expect(query.fromCreator == "Hipyo")
        #expect(query.includeTerms.isEmpty)
        #expect(query.excludeTerms.isEmpty)
        #expect(!query.isEmpty)
    }

    @Test("from: operator combines with text terms")
    func fromOperatorCombinesWithText() {
        let query = SearchQuery("keyboard from:Hipyo")
        #expect(query.fromCreator == "Hipyo")
        #expect(query.includeTerms == ["keyboard"])
    }

    @Test("from: with quoted multi-word creator name")
    func fromOperatorQuoted() {
        let query = SearchQuery(#"from:"Studio No Ha""#)
        #expect(query.fromCreator == "Studio No Ha")
        #expect(query.includeTerms.isEmpty)
    }

    @Test("from: operator with quoted name combined with text terms")
    func fromOperatorQuotedWithTerms() {
        let query = SearchQuery(#"woodworking from:"Studio No Ha" -sponsor"#)
        #expect(query.fromCreator == "Studio No Ha")
        #expect(query.includeTerms == ["woodworking"])
        #expect(query.excludeTerms == ["sponsor"])
    }

    @Test("matches videos by creator when from: is set and channelName matches")
    func fromOperatorMatchesCreator() {
        let query = SearchQuery("from:Hipyo")
        #expect(
            query.matches(
                fields: ["My new keyboard build", "topic"],
                channelName: "Hipyo Tech"
            ) == true
        )
    }

    @Test("rejects videos by other creators when from: is set")
    func fromOperatorRejectsOtherCreators() {
        let query = SearchQuery("from:Hipyo")
        #expect(
            query.matches(
                fields: ["Beautiful build", "topic"],
                channelName: "TaehaTypes"
            ) == false
        )
    }

    @Test("from: substring match is case-insensitive and partial")
    func fromOperatorSubstringMatch() {
        let query = SearchQuery("from:hipyo")
        #expect(
            query.matches(
                fields: ["title"],
                channelName: "Hipyo Tech"
            ) == true
        )
    }

    @Test("from: combined with text terms requires both to match")
    func fromAndTextTermBothRequired() {
        let query = SearchQuery("keyboard from:Hipyo")
        // Hipyo's keyboard video → matches both
        #expect(
            query.matches(
                fields: ["new keyboard build", "topic"],
                channelName: "Hipyo Tech"
            ) == true
        )
        // Hipyo's non-keyboard video → matches creator but not text
        #expect(
            query.matches(
                fields: ["my desk setup", "topic"],
                channelName: "Hipyo Tech"
            ) == false
        )
        // Other creator's keyboard video → matches text but not creator
        #expect(
            query.matches(
                fields: ["new keyboard build", "topic"],
                channelName: "TaehaTypes"
            ) == false
        )
    }

    @Test("from: filter is ignored when channelName is nil (non-video entities)")
    func fromOperatorIgnoredForNonVideos() {
        let query = SearchQuery("from:Hipyo")
        // Topic name match (no channelName) should ignore from: rather than reject.
        #expect(query.matches(fields: ["Mechanical Keyboards"]) == true)
    }
}
