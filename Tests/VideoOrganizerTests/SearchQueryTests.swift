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
}
