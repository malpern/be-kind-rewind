import SwiftUI
import TaggingKit

/// Right-hand detail panel showing metadata, playlists, and actions for the selected video.
struct VideoInspector: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache
    @Bindable var displaySettings: DisplaySettings

    private var inspectedItem: InspectedVideoViewModel? { store.inspectedItem }
    private var video: VideoViewModel? { inspectedItem?.video }
    private var isSelected: Bool {
        guard let inspectedId = store.inspectedVideoId else { return false }
        return store.selectedVideoIds.contains(inspectedId)
    }

    private enum InspectorMetrics {
        static let minWidth: CGFloat = 296
        static let idealWidth: CGFloat = 320
        static let maxWidth: CGFloat = 344
        static let titleLineSpacing: CGFloat = 3
        static let paragraphLineSpacing: CGFloat = 4
        static let compactLineSpacing: CGFloat = 2
        static let sectionSpacing: CGFloat = 18
        static let sectionDividerVerticalPadding: CGFloat = 6
        static let metadataLabelWidth: CGFloat = 90
        static let thumbnailCornerRadius: CGFloat = 10
        static let inlineThumbnailCornerRadius: CGFloat = 6
        static let rowSpacing: CGFloat = 12
    }

    var body: some View {
        Group {
            // Removed the auto-forward to the creator detail page that used
            // to fire when `inspectedCreatorName` was set. That was invisible
            // magic — opening the inspector with a filter active would silently
            // navigate, which conflated two unrelated concepts. Navigation
            // now happens via the explicit "Open Creator Page" button on the
            // creator filter chip in the grid header (CollectionGridView) and
            // via double-click on a creator circle.
            if let inspectedItem {
                inspectorContent(inspectedItem)
            } else {
                emptyState
            }
        }
        .frame(
            minWidth: InspectorMetrics.minWidth,
            idealWidth: InspectorMetrics.idealWidth,
            maxWidth: InspectorMetrics.maxWidth
        )
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.and.hand.point.up.left")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select a video")
                .appSectionHeader()
            Text("Hover a card to preview it here, or select one to see actions, tags, and playlist details.")
                .appSecondary()
                .lineSpacing(InspectorMetrics.paragraphLineSpacing)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .frame(maxHeight: .infinity)
    }

    /// Main inspector body showing thumbnail, title, channel info, metadata, tags, and action buttons.
    private func inspectorContent(_ inspectedItem: InspectedVideoViewModel) -> some View {
        let video = inspectedItem.video
        let channelPresentation = store.channelPresentation(for: video)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ThumbnailView(videoId: video.videoId, thumbnailUrl: video.thumbnailUrl, cacheDir: thumbnailCache.cacheDirURL)
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.thumbnailCornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                    HighlightedText(video.title, terms: store.parsedQuery.includeTerms)
                        .appPageTitle()
                        .fontWeight(.semibold)
                        .lineSpacing(InspectorMetrics.titleLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if let channel = channelPresentation.name {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 10) {
                                Button {
                                    if let topicId = store.navigateToCreator(
                                        channelId: video.channelId,
                                        channelName: channel,
                                        preferredTopicId: video.topicId
                                    ) {
                                        displaySettings.scrollToTopicRequested = topicId
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        channelAvatar(channelPresentation)
                                        HighlightedText(channel, terms: store.parsedQuery.includeTerms)
                                            .appPrimary()
                                            .fontWeight(.medium)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Filter the library to this creator")
                                .contentShape(Rectangle())
                                .contextMenu {
                                    if let channelUrl = channelPresentation.channelUrl.flatMap(URL.init(string:)) {
                                        Button("Open Channel on YouTube") {
                                            NSWorkspace.shared.open(channelUrl)
                                        }
                                    }
                                }

                                Spacer(minLength: 8)

                                // Blue primary CTA right next to the creator
                                // name. App Store "Go To Artist" pattern —
                                // the most prominent affordance for opening
                                // the creator's full detail page lives in the
                                // entity's row, not buried in an actions
                                // stack at the bottom of the inspector.
                                if let channelId = video.channelId, !channelId.isEmpty {
                                    Button {
                                        store.openCreatorDetail(channelId: channelId)
                                    } label: {
                                        Label("Open", systemImage: "chevron.right.circle.fill")
                                            .labelStyle(.titleAndIcon)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .help("Open the full creator detail page for \(channel)")
                                    .accessibilityIdentifier("openCreatorPageFromInspector")
                                }
                            }

                            if let subtitle = inspectorSubtitle(for: video), !subtitle.isEmpty {
                                Text(subtitle)
                                    .appMetadata()
                                    .textCase(.uppercase)
                                    .tracking(0.4)
                            }
                        }
                    }

                    sectionDivider()

                    tagsSection(inspectedItem)

                    if !inspectedItem.playlists.isEmpty || inspectedItem.isWatchCandidate || inspectedItem.seenSummary != nil {
                        sectionDivider()
                    }

                    metadataGrid(video)

                    if isSelected {
                        sectionDivider()
                        actionButtons(inspectedItem)
                    }

                    let moreVideos = store.moreFromChannel(videoId: video.videoId)
                    if !moreVideos.isEmpty {
                        sectionDivider()
                        moreFromChannel(moreVideos, channelName: video.channelName)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
        }
    }

    @ViewBuilder
    private func channelAvatar(_ presentation: ChannelPresentation) -> some View {
        if let data = presentation.iconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else if let iconUrl = presentation.iconUrl.flatMap(URL.init(string:)) {
            AsyncImage(url: iconUrl) { phase in
                if case .success(let image) = phase {
                    image.resizable()
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.circle.fill")
                .resizable()
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
        }
    }

    // MARK: - Metadata Grid

    private func inspectorSubtitle(for video: VideoViewModel) -> String? {
        let parts: [String] = [video.publishedAt, video.viewCount]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
    }

    private func sectionDivider() -> some View {
        Divider()
            .padding(.vertical, InspectorMetrics.sectionDividerVerticalPadding)
    }

    @ViewBuilder
    private func tagsSection(_ inspectedItem: InspectedVideoViewModel) -> some View {
        let tags = inspectorTags(for: inspectedItem)
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tags")
                    .appSectionHeader()
                    .foregroundStyle(.secondary)

                FlexibleTagList(tags: tags) { tag in
                    if tag == "Watch Candidate" { return .orange }
                    if tag == "Seen" { return .green }
                    return .accentColor
                } onSelect: { tag in
                    guard tag != "Watch Candidate",
                          tag != "Seen",
                          let playlist = inspectedItem.playlists.first(where: { $0.title == tag }) else { return }
                    store.applyPlaylistFilter(playlist)
                }
            }
        }
    }

    private func metadataGrid(_ video: VideoViewModel) -> some View {
        let playlists = store.playlistsForVideo(video.videoId)
        return Grid(alignment: .leading, verticalSpacing: 8) {
            if let views = video.viewCount {
                metadataRow(icon: "eye", label: "Views", value: views)
            }
            if let date = video.publishedAt {
                metadataRow(icon: "calendar", label: "Published", value: date)
            }
            if let duration = video.duration {
                metadataRow(icon: "clock", label: "Duration", value: duration, mono: true)
            }
            if let topic = store.topicNameForVideo(video.videoId) {
                metadataRow(icon: "folder", label: "Topic", value: topic)
            }
            if !playlists.isEmpty {
                metadataRow(icon: "music.note.list", label: "Playlists", value: "\(playlists.count)")
            }
            if let seenSummary = store.seenSummary(for: video.videoId) {
                metadataRow(icon: "checkmark.circle", label: "Seen", value: seenLabel(for: seenSummary))
            }
        }
    }

    private func inspectorTags(for inspectedItem: InspectedVideoViewModel) -> [String] {
        var tags = inspectedItem.playlists.map(\.title)
        if inspectedItem.seenSummary != nil {
            tags.insert("Seen", at: 0)
        }
        if inspectedItem.isWatchCandidate {
            tags.insert("Watch Candidate", at: 0)
        }
        return tags
    }

    private func seenLabel(for summary: SeenVideoSummary) -> String {
        if let latestSeenAt = summary.latestSeenAt {
            return "Imported history (\(latestSeenAt))"
        }
        return "Imported history"
    }

    @ViewBuilder
    private func metadataRow(icon: String, label: String, value: String, mono: Bool = false) -> some View {
        GridRow {
            Label(label, systemImage: icon)
                .appMetadata()
                .frame(width: InspectorMetrics.metadataLabelWidth, alignment: .leading)
            Text(value)
                .font(mono ? Typography.primary.monospacedDigit() : Typography.primary)
                .lineSpacing(InspectorMetrics.compactLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    /// Context-sensitive action buttons: Save/Dismiss for watch candidates, playlist management for saved videos.
    private func actionButtons(_ inspectedItem: InspectedVideoViewModel) -> some View {
        let video = inspectedItem.video
        return VStack(spacing: 10) {
            Button {
                if let url = video.youtubeUrl {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open on YouTube", systemImage: "play.rectangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help("Open this video on YouTube")
            // Copy Link button removed — low-value duplication of the
            // system Share sheet, and the row was crowding the inspector.
            // Use the right-click context menu on the title or thumbnail
            // for copy operations.

            if inspectedItem.isWatchCandidate, let topicId = store.selectedTopicId {
                sectionDivider()

                Button(role: .destructive) {
                    store.dismissCandidate(topicId: topicId, videoId: video.videoId)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .help("Hide this candidate from the topic")

                Button {
                    store.saveCandidateToWatchLater(topicId: topicId, videoId: video.videoId)
                } label: {
                    Label("Save to Watch Later", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .help("Queue this video for Watch Later")

                Menu {
                    ForEach(store.knownPlaylists()) { playlist in
                        Button(playlist.title) {
                            store.saveCandidateToPlaylist(topicId: topicId, videoId: video.videoId, playlist: playlist)
                        }
                    }
                } label: {
                    Label("Save to Playlist", systemImage: "music.note.list")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(store.knownPlaylists().isEmpty)
                .help(store.knownPlaylists().isEmpty ? "No playlists available" : "Choose a playlist")

                Button(role: .destructive) {
                    store.markCandidateNotInterested(topicId: topicId, videoId: video.videoId)
                } label: {
                    Label("Not Interested", systemImage: "hand.thumbsdown")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .help("Hide locally and queue a future YouTube Not Interested action")

                if let channelId = video.channelId, !channelId.isEmpty {
                    Button(role: .destructive) {
                        store.excludeCreatorFromWatch(
                            channelId: channelId,
                            channelName: video.channelName,
                            channelIconUrl: video.channelIconUrl
                        )
                    } label: {
                        Label("Exclude Creator from Watch", systemImage: "person.crop.circle.badge.xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                    .help("Hide this creator from future Watch discovery until restored in Settings")
                }
            }
        }
    }

    // MARK: - Creator Detail

    /// Full creator profile view showing subscriber count, coverage stats, and per-topic video breakdown.
    private func creatorInspectorContent(_ detail: CreatorDetailViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Large channel icon
                HStack {
                    Spacer()
                    creatorIcon(detail)
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                    Spacer()
                }
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
                    // Name + tier — name doubles as the entry point for the new
                    // creator detail page when we know the channelId.
                    VStack(spacing: 4) {
                        if let channelId = detail.channelId {
                            Button {
                                store.openCreatorDetail(channelId: channelId)
                            } label: {
                                Text(detail.channelName)
                                    .appHeroTitle()
                                    .fontWeight(.semibold)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .help("Open creator detail page")
                            .accessibilityIdentifier("openCreatorDetailFromInspector")
                        } else {
                            Text(detail.channelName)
                                .appHeroTitle()
                                .fontWeight(.semibold)
                                .textSelection(.enabled)
                        }

                        if let subs = detail.formattedSubscribers, let tier = detail.subscriberTier {
                            Text("\(subs) · \(tier)")
                                .appSecondary()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    sectionDivider()

                    // Stats
                    Grid(alignment: .leading, verticalSpacing: 8) {
                        metadataRow(icon: "video", label: "Saved", value: "\(detail.totalVideoCount) videos")
                        if let coverage = detail.coverageText {
                            metadataRow(icon: "chart.pie", label: "Coverage", value: coverage)
                        }
                        if detail.totalViews > 0 {
                            metadataRow(icon: "eye", label: "Views", value: detail.formattedViews)
                        }
                        if let velocity = detail.velocityText {
                            metadataRow(icon: "bolt", label: "Recent", value: velocity)
                        }
                        if let newest = detail.newestAge {
                            metadataRow(icon: "calendar", label: "Newest", value: newest)
                        }
                        if let oldest = detail.oldestAge {
                            metadataRow(icon: "calendar.badge.clock", label: "Oldest", value: oldest)
                        }
                    }

                    sectionDivider()

                    // Topic breakdown
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Topics")
                            .appSectionHeader()
                            .foregroundStyle(.secondary)

                        ForEach(detail.videosByTopic, id: \.topicName) { entry in
                            HStack {
                                Image(systemName: TopicTheme.iconName(for: entry.topicName))
                                    .font(Typography.metadata)
                                    .foregroundStyle(TopicTheme.iconColor(for: entry.topicName))
                                    .frame(width: 20)
                                Text(entry.topicName)
                                    .appPrimary()
                                    .lineLimit(1)
                                Spacer()
                                Text("\(entry.videos.count)")
                            .font(Typography.primary.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private func creatorIcon(_ detail: CreatorDetailViewModel) -> some View {
        if let data = detail.channelIconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let urlString = detail.channelIconUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    creatorPlaceholder(detail.channelName)
                }
            }
        } else {
            creatorPlaceholder(detail.channelName)
        }
    }

    private func creatorPlaceholder(_ name: String) -> some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.15))
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - More from Channel

    /// Scrollable row of other videos from the same channel in your library.
    private func moreFromChannel(_ videos: [VideoViewModel], channelName: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("More from \(channelName ?? "this channel")")
                .appSectionHeader()
                .foregroundStyle(.secondary)

            ForEach(videos, id: \.videoId) { v in
                Button {
                    store.selectedVideoId = v.videoId
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            ThumbnailView(videoId: v.videoId, thumbnailUrl: v.thumbnailUrl, cacheDir: thumbnailCache.cacheDirURL)
                                .frame(width: 80, height: 45)
                                .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.inlineThumbnailCornerRadius, style: .continuous))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.title)
                                    .appPrimary()
                                    .fontWeight(.medium)
                                    .lineSpacing(InspectorMetrics.compactLineSpacing)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                if let meta = [v.viewCount, v.publishedAt].compactMap({ $0 }).joined(separator: " • ") as String?,
                                   !meta.isEmpty {
                                    Text(meta)
                                        .appMetadata()
                                }
                            }
                        }
                        .padding(.vertical, 6)

                        if v.videoId != videos.last?.videoId {
                            Divider()
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FlexibleTagList: View {
    let tags: [String]
    let colorForTag: (String) -> Color
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { tag in
                        tagChip(tag)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        let chip = Text(tag)
            .appMetadata()
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(colorForTag(tag).opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(colorForTag(tag).opacity(0.28), lineWidth: 1)
            )

        if let onSelect, tag != "Watch Candidate" {
            Button {
                onSelect(tag)
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .help("Filter library to playlist \(tag)")
        } else {
            chip
        }
    }

    private var rows: [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var width = 0
        let maxWidth = 26

        for tag in tags {
            let proposed = width + tag.count + (current.isEmpty ? 0 : 2)
            if proposed > maxWidth && !current.isEmpty {
                result.append(current)
                current = [tag]
                width = tag.count
            } else {
                current.append(tag)
                width = proposed
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }
}
