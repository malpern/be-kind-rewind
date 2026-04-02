import SwiftUI

struct CreatorSectionHeaderView: View {
    let channelName: String
    let channelIconUrl: URL?
    let count: Int
    var totalCount: Int?
    let topicNames: [String]
    let sectionId: String
    let progress: Double
    var highlightTerms: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                channelIcon

                HighlightedText(channelName, terms: highlightTerms)
                    .font(.title3.bold())

                countBadge

                if !topicNames.isEmpty {
                    topicPills
                }

                Spacer()
            }
            .padding(.horizontal, GridConstants.horizontalPadding)
            .padding(.vertical, 10)

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
        }
        .background(.bar)
    }

    private var channelIcon: some View {
        Group {
            if let url = channelIconUrl {
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }

    private var countBadge: some View {
        Group {
            if let total = totalCount, total != count {
                Text("\(count) of \(total) saved")
            } else {
                Text("\(count)")
            }
        }
        .font(.caption.monospacedDigit().bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private var topicPills: some View {
        HStack(spacing: 4) {
            ForEach(topicNames.prefix(3), id: \.self) { name in
                Text(shortenTopicName(name))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if topicNames.count > 3 {
                Text("+\(topicNames.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private func shortenTopicName(_ name: String) -> String {
        // Truncate long topic names for pills
        if name.count > 20 {
            return String(name.prefix(18)) + "..."
        }
        return name
    }
}
