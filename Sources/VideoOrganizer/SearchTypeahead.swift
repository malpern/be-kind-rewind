import SwiftUI

/// Typeahead dropdown showing topic and channel suggestions.
struct SearchTypeahead: View {
    let suggestions: [TypeaheadSuggestion]
    let searchText: String
    let onSelect: (TypeaheadSuggestion) -> Void

    /// The token shown highlighted as the user's "typed" text. For `from:` suggestions
    /// the highlight should match against the partial after `from:`, not the literal
    /// search text including the operator.
    private var highlightToken: String {
        if let last = searchText.split(separator: " ", omittingEmptySubsequences: false).last,
           last.hasPrefix("from:") {
            var partial = String(last.dropFirst("from:".count))
            if partial.hasPrefix("@") { partial.removeFirst() }
            if partial.hasPrefix("\"") { partial.removeFirst() }
            return partial
        }
        return searchText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: suggestion.icon)
                            .font(.subheadline)
                            .foregroundStyle(suggestion.kind == .topic ? TopicTheme.iconColor(for: suggestion.text) : .secondary)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            TypeaheadText(text: suggestion.text, typed: highlightToken)
                            if suggestion.kind == .fromCreator, let handle = suggestion.handle, !handle.isEmpty {
                                Text(handle.hasPrefix("@") ? handle : "@\(handle)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Text("\(suggestion.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if suggestion.id != suggestions.last?.id {
                    Divider().padding(.leading, 38)
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }
}

/// Renders text with already-typed portion de-emphasized and the completion emphasized.
private struct TypeaheadText: View {
    let text: String
    let typed: String

    var body: some View {
        if let range = text.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) {
            let before = String(text[text.startIndex..<range.lowerBound])
            let match = String(text[range])
            let after = String(text[range.upperBound...])

            Text(before).foregroundStyle(.tertiary)
            + Text(match).foregroundStyle(.tertiary)
            + Text(after).foregroundStyle(.primary).bold()
        } else {
            Text(text)
        }
    }
}
