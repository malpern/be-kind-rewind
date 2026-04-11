import SwiftUI

/// Header row for a creator group in the grid, showing channel icon, name, and video count.
struct CreatorSectionHeaderView: View {
    let channelName: String
    let channelIconUrl: URL?
    /// Locally cached icon bytes from `ChannelRecord.iconData`. Required
    /// for the row to render the avatar offline; the row falls back to the
    /// network only when this is nil.
    var channelIconData: Data? = nil
    let channelUrl: URL?
    let count: Int
    var totalCount: Int?
    let topicNames: [String]
    let sectionId: String
    let progress: Double
    var highlightTerms: [String] = []

    var body: some View {
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
        .background(.bar)
        .contextMenu {
            if let channelUrl {
                Button("Open Channel on YouTube") {
                    NSWorkspace.shared.open(channelUrl)
                }
            }
        }
    }

    private var channelIcon: some View {
        ChannelIconView(
            iconData: channelIconData,
            fallbackUrl: channelIconUrl
        )
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
