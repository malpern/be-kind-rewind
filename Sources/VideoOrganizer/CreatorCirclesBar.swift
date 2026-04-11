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
    /// Double-click and context-menu "Open Creator Page" handler. Distinct
    /// from `onSelect` (which toggles the topic-grid filter on single click)
    /// so the two interactions don't fight each other. Optional so existing
    /// callers that don't need detail-page navigation can pass nil.
    var onOpenDetail: ((String) -> Void)? = nil

    /// Phase 3: top theme labels for a creator, used by the active-filter
    /// preview chip to show "what they make". Reads from the LLM-cached
    /// `creator_themes` SQLite table at the call site. Empty when the
    /// creator hasn't been classified yet.
    var themeLabelsForChannel: ((String) -> [String])? = nil

    /// Phase 3: subscriber count for a creator (already formatted as a
    /// display string like "150K subscribers"), used by the active-filter
    /// preview chip. Optional so existing callers can pass nil.
    var subscriberCountForChannel: ((String) -> String?)? = nil

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
            VStack(spacing: 6) {
                scrollableCircles
                filterChip
            }
            .padding(.vertical, 8)
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
                    .font(.footnote)
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
                    .font(.footnote)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: size + 16)
            }
        }
        .buttonStyle(.plain)
        .help(channelTooltip(channel, count: count, recent: recent))
        // Double-click → open creator detail page. Attached as a high-priority
        // gesture so it wins over the Button's single-tap handler before the
        // double-tap timer expires. The Button's onSelect (single click) only
        // fires if the double-tap doesn't trigger.
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                onOpenDetail?(channel.channelId)
            }
        )
        .contextMenu {
            Button("Open Creator Page") {
                onOpenDetail?(channel.channelId)
            }
            .disabled(onOpenDetail == nil)
            Divider()
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

    /// Active-filter preview shown below the face-pile circles when a creator
    /// filter is active. Compact, single-insight design — one row only:
    ///
    ///   [avatar 32]  Channel Name             [↗ icon] [×]
    ///                Top Theme
    ///
    /// One insight only — the primary theme tag from the LLM cache (or a
    /// fallback when not classified). No stats join, no multi-theme list.
    /// Right side: icon-only nav button (chevron-right circle) → opens the
    /// detail page, plus the × clear button. The whole left side (avatar +
    /// name + insight) is also a click target so the discoverability problem
    /// stays solved without the icon button needing to advertise itself
    /// with words.
    @ViewBuilder
    private var filterChip: some View {
        if let selectedId = selectedChannelId,
           let channel = channels.first(where: { $0.channelId == selectedId }) {
            HStack(spacing: 10) {
                Button {
                    onOpenDetail?(channel.channelId)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        channelIcon(channel, size: 36)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            chipInsight(for: channel)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onOpenDetail == nil)
                .help("Open the creator page for \(channel.name)")
                .accessibilityIdentifier("creatorFilterPreview")

                if onOpenDetail != nil {
                    Button {
                        onOpenDetail?(channel.channelId)
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .help("Open the creator page for \(channel.name)")
                    .accessibilityIdentifier("creatorFilterOpenDetail")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        onSelect(selectedId)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the creator filter")
                .accessibilityIdentifier("creatorFilterClear")
                .padding(.trailing, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// The single insight rendered below the channel name. Picks the most
    /// distinctive thing we know about the creator and renders it as a
    /// colored capsule echoing the theme capsule visual language used on
    /// the creator detail page. Priority order:
    ///
    /// 1. Primary LLM theme — the highest-signal "what they make" answer
    /// 2. Channel description first sentence — fallback for un-classified
    ///    creators
    /// 3. "N saved" count — last-resort fallback so the row never feels empty
    @ViewBuilder
    private func chipInsight(for channel: ChannelRecord) -> some View {
        let themes = themeLabelsForChannel?(channel.channelId) ?? []
        if let topTheme = themes.first {
            Text(topTheme)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                )
        } else if let description = channel.description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ".")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
                  !description.isEmpty {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            let count = videoCountForChannel(channel.channelId)
            Text("\(count) video\(count == 1 ? "" : "s") saved")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Format an absolute publish date as a short relative age, matching the
    /// "2mo ago" / "5d ago" style used elsewhere on the creator page.
    private func relativeAge(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let days = Int(interval / 86_400)
        if days <= 0 { return "today" }
        if days == 1 { return "1d ago" }
        if days < 30 { return "\(days)d ago" }
        let months = days / 30
        if months == 1 { return "1mo ago" }
        if months < 12 { return "\(months)mo ago" }
        let years = days / 365
        return years == 1 ? "1y ago" : "\(years)y ago"
    }
}
