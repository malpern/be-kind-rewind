import Foundation

/// Parses the main app search input into structured operators + free terms.
///
/// Supports three token forms:
/// - Free terms: `keyboard cherry` → both must appear in some field
/// - Exclude: `-foo` → must NOT appear in any field
/// - `from:` operator: `from:Hipyo` → narrows to videos by a specific creator
///   (substring match on channel name). Quoted form `from:"Studio No Ha"`
///   is supported for creator names with spaces.
///
/// Examples:
/// - `from:Hipyo` → all saved videos by Hipyo Tech
/// - `keyboard from:Hipyo` → keyboard videos by Hipyo Tech only
/// - `from:"Studio No Ha"` → exact phrase creator match
struct SearchQuery: Equatable {
    let includeTerms: [String]
    let excludeTerms: [String]
    /// Optional creator-name filter from `from:CreatorName` operator. nil means no
    /// creator filter is active. Multiple `from:` operators are not supported (only
    /// the last one wins) — deliberate simplification, can extend later if needed.
    let fromCreator: String?

    var isEmpty: Bool {
        includeTerms.isEmpty && excludeTerms.isEmpty && fromCreator == nil
    }

    init(_ rawText: String) {
        // Two-pass tokenizer: first extract `from:"..."` quoted forms (which contain
        // spaces and would otherwise be split by the simple split below), then split
        // the remaining text on whitespace.
        var working = rawText
        var fromValue: String?

        // Match from:"..." with quoted value containing spaces.
        if let quotedRange = working.range(of: #"from:"([^"]+)""#, options: .regularExpression) {
            let matched = String(working[quotedRange])
            if let openQuote = matched.firstIndex(of: "\""),
               let closeQuote = matched.lastIndex(of: "\""),
               openQuote != closeQuote {
                let value = String(matched[matched.index(after: openQuote)..<closeQuote])
                fromValue = value
            }
            working.removeSubrange(quotedRange)
        }

        let tokens = working
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        var inc: [String] = []
        var exc: [String] = []
        for token in tokens {
            if token.hasPrefix("from:"), token.count > "from:".count {
                fromValue = String(token.dropFirst("from:".count))
            } else if token.hasPrefix("-"), token.count > 1 {
                exc.append(String(token.dropFirst()))
            } else {
                inc.append(token)
            }
        }
        self.includeTerms = inc
        self.excludeTerms = exc
        self.fromCreator = fromValue
    }

    /// ALL include terms must appear in at least one field.
    /// NO exclude terms may appear in any field.
    /// IF a `from:` filter is set AND the caller passes a channel name, the channel
    /// must contain the filter substring. When the caller does NOT pass a channel
    /// name, the `from:` filter is ignored — useful for filtering non-video entities
    /// like topic names in the sidebar, where the creator concept doesn't apply.
    func matches(fields: [String], channelName: String? = nil) -> Bool {
        if let fromCreator, !fromCreator.isEmpty, let channelName {
            guard channelName.localizedStandardContains(fromCreator) else {
                return false
            }
        }
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
