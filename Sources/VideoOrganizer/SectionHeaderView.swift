import SwiftUI

/// Header row for a topic section in the grid, showing name and video count.
struct SectionHeaderView: View {
    let name: String
    let count: Int
    var totalCount: Int?
    let topicId: Int64
    let progress: Double
    var showProgress: Bool = true
    var highlightTerms: [String] = []
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: TopicTheme.iconName(for: name))
                .font(.title3)
                .foregroundStyle(.white)

            HighlightedText(name, terms: highlightTerms)
                .font(.title3.bold())

            Group {
                if let total = totalCount {
                    Text("\(count) of \(total)")
                } else {
                    Text("\(count)")
                }
            }
            .font(.caption.monospacedDigit().bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())

            Spacer()
        }
        .padding(.horizontal, GridConstants.horizontalPadding)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
