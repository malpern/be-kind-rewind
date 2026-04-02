import SwiftUI

struct HighlightedText: View {
    let text: String
    let terms: [String]

    init(_ text: String, terms: [String]) {
        self.text = text
        self.terms = terms
    }

    var body: some View {
        if terms.isEmpty {
            Text(text)
        } else {
            Text(highlightedString)
        }
    }

    private var highlightedString: AttributedString {
        var attributed = AttributedString(text)

        for term in terms {
            var searchStart = text.startIndex
            while let range = text.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
            ) {
                if let attrStart = AttributedString.Index(range.lowerBound, within: attributed),
                   let attrEnd = AttributedString.Index(range.upperBound, within: attributed) {
                    attributed[attrStart..<attrEnd].foregroundColor = .accentColor
                    attributed[attrStart..<attrEnd].inlinePresentationIntent = .stronglyEmphasized
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}
