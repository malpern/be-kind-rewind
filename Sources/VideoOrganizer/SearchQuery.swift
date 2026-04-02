import Foundation

struct SearchQuery: Equatable {
    let includeTerms: [String]
    let excludeTerms: [String]

    var isEmpty: Bool { includeTerms.isEmpty && excludeTerms.isEmpty }

    init(_ rawText: String) {
        let tokens = rawText
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        var inc: [String] = []
        var exc: [String] = []
        for token in tokens {
            if token.hasPrefix("-"), token.count > 1 {
                exc.append(String(token.dropFirst()))
            } else {
                inc.append(token)
            }
        }
        self.includeTerms = inc
        self.excludeTerms = exc
    }

    /// ALL include terms must appear in at least one field.
    /// NO exclude terms may appear in any field.
    func matches(fields: [String]) -> Bool {
        for term in excludeTerms {
            if fields.contains(where: { $0.localizedStandardContains(term) }) {
                return false
            }
        }
        for term in includeTerms {
            if !fields.contains(where: { $0.localizedStandardContains(term) }) {
                return false
            }
        }
        return true
    }
}
