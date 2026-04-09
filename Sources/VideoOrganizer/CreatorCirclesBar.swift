import SwiftUI
import TaggingKit

/// Horizontal scrollable row of circular channel avatars for filtering by creator within a topic.
struct CreatorCirclesBar: View {
    let channels: [ChannelRecord]
    let selectedChannelId: String?
    let topicId: Int64
    let collapseLowCountCreators: Bool
    let prioritizeRecency: Bool
    let videoCountForChannel: (String) -> Int
    let hasRecentContent: (String) -> Bool  // true if creator has video from last 7 days
    let latestPublishedAtForChannel: (String) -> Date?
    let onSelect: (String) -> Void

    @State private var isExpanded = false

    private let circleSize: CGFloat = 44
    private let collapsedCircleSize: CGFloat = 32
    private let spacing: CGFloat = 12

    private var allSortedChannels: [ChannelRecord] {
        channels.sorted(by: compareChannels)
    }

    /// Channels with >2 videos shown prominently; ≤2 collapsed behind "+N more"
    private var prominentChannels: [ChannelRecord] {
        guard collapseLowCountCreators else { return allSortedChannels }
        return channels.filter { videoCountForChannel($0.channelId) > 2 }
    }

    private var collapsedChannels: [ChannelRecord] {
        guard collapseLowCountCreators else { return [] }
        return channels.filter { videoCountForChannel($0.channelId) <= 2 }
    }

    var body: some View {
        if channels.isEmpty { EmptyView() } else {
            VStack(spacing: 4) {
                scrollableCircles
                filterChip
            }
            .padding(.vertical, 6)
            .padding(.horizontal, GridConstants.horizontalPadding)
            .background(.bar)
        }
    }

    // MARK: - Circles Row

    private var scrollableCircles: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(sortedProminent) { channel in
                        creatorCircle(channel, size: circleSize)
                    }

                    if !collapsedChannels.isEmpty {
                        if isExpanded {
                            ForEach(sortedCollapsed) { channel in
                                creatorCircle(channel, size: collapsedCircleSize)
                                    .id("collapsed-\(channel.channelId)")
                            }
                        } else {
                            expandButton
                                .id("expand-button")
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 8)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 8)
                }
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded, let first = sortedCollapsed.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("collapsed-\(first.channelId)", anchor: .leading)
                        }
                    }
                }
            }
        }
    }

    /// Sort by recency-weighted score: recent content floats left, then by video count
    private var sortedProminent: [ChannelRecord] {
        prominentChannels.sorted(by: compareChannels)
    }

    private var sortedCollapsed: [ChannelRecord] {
        collapsedChannels.sorted(by: compareChannels)
    }

    private func compareChannels(_ a: ChannelRecord, _ b: ChannelRecord) -> Bool {
        if prioritizeRecency {
            let aLatest = latestPublishedAtForChannel(a.channelId)
            let bLatest = latestPublishedAtForChannel(b.channelId)
            switch (aLatest, bLatest) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
        }

        let aRecent = hasRecentContent(a.channelId)
        let bRecent = hasRecentContent(b.channelId)
        if aRecent != bRecent {
            return aRecent && !bRecent
        }

        let aCount = videoCountForChannel(a.channelId)
        let bCount = videoCountForChannel(b.channelId)
        if aCount != bCount {
            return aCount > bCount
        }

        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    // MARK: - Expand Button

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded = true
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: circleSize, height: circleSize)
                    Text("+\(collapsedChannels.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help("\(collapsedChannels.count) creators with 1–2 videos")
    }

    // MARK: - Circle

    private func creatorCircle(_ channel: ChannelRecord, size: CGFloat) -> some View {
        let isSelected = selectedChannelId == channel.channelId
        let count = videoCountForChannel(channel.channelId)
        let recent = hasRecentContent(channel.channelId)

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                onSelect(channel.channelId)
            }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    channelIcon(channel, size: size)
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
                        }
                        .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : .clear, radius: 4)

                    if count > 1 {
                        Text("\(count)")
                            .font(.system(size: size > 36 ? 9 : 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 2, y: 2)
                    }

                    // Recency dot — top-right
                    if recent {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                            .offset(x: 1, y: size > 36 ? -2 : -1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(width: size, height: size)

                Text(channel.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: size + 16)
            }
        }
        .buttonStyle(.plain)
        .help(channelTooltip(channel, count: count, recent: recent))
        .contextMenu {
            if let urlString = channel.channelUrl, let url = URL(string: urlString) {
                Button("Open Channel on YouTube") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                Button("Open Channel on YouTube") {
                    let url = URL(string: "https://www.youtube.com/channel/\(channel.channelId)")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .transition(.opacity.combined(with: .scale))
    }

    @ViewBuilder
    private func channelIcon(_ channel: ChannelRecord, size: CGFloat) -> some View {
        if let data = channel.iconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let urlString = channel.iconUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                channelPlaceholder(channel, size: size)
            }
        } else {
            channelPlaceholder(channel, size: size)
        }
    }

    private func channelPlaceholder(_ channel: ChannelRecord, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.15))
            Text(String(channel.name.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func channelTooltip(_ channel: ChannelRecord, count: Int, recent: Bool) -> String {
        var parts = [channel.name]
        if let handle = channel.handle {
            parts.append(handle)
        }
        if let subs = channel.subscriberCount, let num = Int(subs) {
            parts.append(formatSubscribers(num))
        }
        parts.append("\(count) video\(count == 1 ? "" : "s") in this topic")
        if recent {
            parts.append("New content this week")
        }
        if let desc = channel.description, !desc.isEmpty {
            parts.append(String(desc.prefix(100)))
        }
        return parts.joined(separator: "\n")
    }

    private func formatSubscribers(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM subscribers", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK subscribers", Double(count) / 1_000)
        }
        return "\(count) subscribers"
    }

    // MARK: - Filter Chip

    @ViewBuilder
    private var filterChip: some View {
        if let selectedId = selectedChannelId,
           let channel = channels.first(where: { $0.channelId == selectedId }) {
            let count = videoCountForChannel(selectedId)
            HStack(spacing: 4) {
                Text("Showing: \(channel.name) (\(count) video\(count == 1 ? "" : "s"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        onSelect(selectedId)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
