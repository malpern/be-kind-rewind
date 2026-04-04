import SwiftUI

struct SectionHeaderView: View {
    let name: String
    let count: Int
    var totalCount: Int?
    let topicId: Int64
    let progress: Double
    var showProgress: Bool = true
    var highlightTerms: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: TopicTheme.iconName(for: name))
                    .font(.title3)
                    .foregroundStyle(TopicTheme.iconColor(for: name))

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

            if !showProgress {
                Color.clear.frame(height: 0)
            } else {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.1))
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * max(progress, 0))
                            .animation(.easeOut(duration: GridConstants.progressAnimationDuration), value: progress)
                    }
                }
                .frame(height: GridConstants.progressBarHeight)
                .opacity(showProgress ? 1 : 0)
                .accessibilityHidden(!showProgress)
            }
        }
        .background(.bar)
    }
}
