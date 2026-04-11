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

    /// Active-filter banner shown below the face-pile circles whenever a
    /// creator filter is active. Reads as a contextual extension of the
    /// circles row (same `.bar` background, same horizontal padding) rather
    /// than a separate page-level chrome strip — that placement is the
    /// macOS-native version of "filter is active here, here are the relevant
    /// actions" (Mail's message list does the same with its own filter row).
    ///
    /// Three controls:
    /// - "Showing N video(s)" caption (no longer duplicates the channel name
    ///   since the highlighted circle above already identifies the creator)
    /// - "Open Creator Page" bordered button → discoverable CTA to navigate
    ///   to the dedicated detail view
    /// - "Clear filter" × button → mirrors the click-again-to-deselect
    ///   behavior on the circles, for users who prefer an explicit affordance
    /// Active-filter preview shown below the face-pile circles when a creator
    /// filter is active. Designed as a *value preview* rather than a generic
    /// "Open Creator Page" CTA: the avatar + name + stats + theme list
    /// already communicate what the creator is about and what richer info
    /// lives behind the click. Clicking the preview itself opens the detail
    /// page. The right edge has a separate × clear button.
    ///
    /// Two lines (or one if no themes available):
    ///   [avatar] Name · 12 saved · 2mo ago
    ///            Switch Reviews · Web Dev · Office Chairs
    @ViewBuilder
    private var filterChip: some View {
        if let selectedId = selectedChannelId,
           let channel = channels.first(where: { $0.channelId == selectedId }) {
            HStack(spacing: 12) {
                Button {
                    onOpenDetail?(channel.channelId)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        channelIcon(channel, size: 36)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            chipPrimaryLine(channel)
                            chipSecondaryLine(channel)
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

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        onSelect(selectedId)
                    }
                } label: {
                    Label("Clear", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Clear the creator filter")
                .accessibilityIdentifier("creatorFilterClear")
                .padding(.trailing, 4)
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

    /// Top line: channel name in primary text, then dot-separated stats
    /// (topic-scoped video count, formatted subscriber count, last-upload
    /// age). Each stat is omitted gracefully when its data isn't available.
    @ViewBuilder
    private func chipPrimaryLine(_ channel: ChannelRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(channel.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("·")
                .font(.body)
                .foregroundStyle(.tertiary)
            Text(chipStatsString(for: channel))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Build the dot-separated stats string for the filter chip's primary
    /// line. Lives outside the @ViewBuilder so we can use ordinary control
    /// flow (var + append) to assemble the parts conditionally.
    private func chipStatsString(for channel: ChannelRecord) -> String {
        let count = videoCountForChannel(channel.channelId)
        var parts: [String] = ["\(count) saved"]
        if let subs = subscriberCountForChannel?(channel.channelId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subs.isEmpty {
            parts.append(subs)
        }
        if let publishedAt = latestPublishedAtForChannel(channel.channelId) {
            parts.append(relativeAge(from: publishedAt))
        }
        return parts.joined(separator: " · ")
    }

    /// Second line: top theme labels separated by middle dots. Reads from
    /// the LLM-cached `creator_themes` table via the closure passed in by
    /// the call site. When no themes are cached, falls back to the channel
    /// description's first sentence so there's still some preview value.
    @ViewBuilder
    private func chipSecondaryLine(_ channel: ChannelRecord) -> some View {
        let themes = themeLabelsForChannel?(channel.channelId) ?? []
        if !themes.isEmpty {
            Text(themes.prefix(4).joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if let description = channel.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !description.isEmpty {
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
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
