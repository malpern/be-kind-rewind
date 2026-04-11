import SwiftUI
import TaggingKit

/// Root three-column layout: topic sidebar, collection grid, and optional inspector.
struct OrganizerView: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache
    @Bindable var displaySettings: DisplaySettings

    /// Bound directly to `NavigationSplitView(columnVisibility:)`. Auto-collapses to
    /// `.detailOnly` when a detail route is pushed (Photos.app / Music.app pattern) and
    /// restores to `.all` when the user navigates back. The toolbar's standard sidebar
    /// toggle (⌘0) lets the user override this at any time.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TopicSidebar(store: store, displaySettings: displaySettings)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            NavigationStack(path: $store.detailPath) {
                CollectionGridView(store: store, thumbnailCache: thumbnailCache, displaySettings: displaySettings)
                    .navigationTitle("")
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            creatorFilterChip
                            if store.selectedTopicId != nil,
                               (store.pageDisplayMode == .saved
                                || (store.pageDisplayMode == .watchCandidates && store.watchPresentationMode == .byTopic)) {
                                TopicScrollProgressBar(progress: store.topicScrollProgress)
                            }
                        }
                    }
                    .inspector(isPresented: $displaySettings.showInspector) {
                        VideoInspector(store: store, thumbnailCache: thumbnailCache, displaySettings: displaySettings)
                            .inspectorColumnWidth(min: 296, ideal: 320, max: 344)
                            .accessibilityIdentifier("videoInspector")
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .automatic) {
                            pageModeControls
                        }

                        ToolbarItemGroup(placement: .automatic) {
                            sortMenu
                        }

                        ToolbarItemGroup(placement: .automatic) {
                            statusIndicators
                        }

                        ToolbarItemGroup(placement: .primaryAction) {
                            Button {
                                displaySettings.showInspector.toggle()
                                displaySettings.toast.show(
                                    displaySettings.showInspector ? "Inspector" : "Inspector Hidden",
                                    icon: "sidebar.trailing"
                                )
                            } label: {
                                Label("Inspector", systemImage: "sidebar.trailing")
                            }
                            .help(displaySettings.showInspector ? "Hide Inspector" : "Show Inspector")
                            .accessibilityIdentifier("toggleInspector")
                            .accessibilityLabel(displaySettings.showInspector ? "Hide inspector panel" : "Show inspector panel")
                        }
                    }
                    .navigationDestination(for: DetailRoute.self) { route in
                        switch route {
                        case .creator(let channelId):
                            CreatorDetailView(
                                store: store,
                                channelId: channelId,
                                thumbnailCache: thumbnailCache
                            )
                        }
                    }
            }
            .onChange(of: store.detailPath) { _, newPath in
                // Auto-collapse the sidebar when entering a detail route, restore when
                // popping back to the grid root. The user's manual toggles via ⌘0 still
                // work — we only flip on path transitions, not on every render.
                if newPath.isEmpty {
                    columnVisibility = .all
                } else {
                    columnVisibility = .detailOnly
                }
            }
        }
        .overlay(alignment: .top) {
            ActionToast(state: displaySettings.toast)
                .padding(.top, 4)
        }
        .onAppear {
            AppLogger.app.info("Main organizer view appeared")
        }
        .onChange(of: displaySettings.showInspector) { _, isPresented in
            AppLogger.app.info("Inspector visibility changed: \(isPresented, privacy: .public)")
        }
        .alert(
            store.alert?.title ?? "",
            isPresented: Binding(
                get: { store.alert != nil },
                set: { if !$0 { store.alert = nil } }
            )
        ) {
            Button("OK") { store.alert = nil }
        } message: {
            if let message = store.alert?.message {
                Text(message)
            }
        }
        .alert(
            store.pendingAPIFallbackApproval?.title ?? "",
            isPresented: Binding(
                get: { store.pendingAPIFallbackApproval != nil },
                set: { if !$0 { store.denyPendingAPIFallback(rememberForPass: false) } }
            ),
            presenting: store.pendingAPIFallbackApproval
        ) { request in
            // Simplified to two buttons. The previous "Use for whole refresh /
            // Don't ask again this refresh" actions belonged in Settings, not
            // in a yes/no decision dialog the user has to read every time.
            Button("Use API") {
                store.approvePendingAPIFallback(rememberForPass: false)
            }
            Button("Skip", role: .cancel) {
                store.denyPendingAPIFallback(rememberForPass: false)
            }
        } message: { request in
            Text(request.message)
        }
        .task {
            // If we launch directly into Watch mode, trigger the refresh cycle
            if store.pageDisplayMode == .watchCandidates {
                store.ensureCandidatesForWatchPage()
            }
            store.refreshYouTubeQuotaSnapshot()
        }
        .task(id: watchThumbnailPrefetchKey) {
            await prefetchWatchThumbnailsIfNeeded()
        }
        .task(id: savedThumbnailPrefetchKey) {
            await prefetchSelectedSavedTopicThumbnailsIfNeeded()
        }
        .accessibilityIdentifier("mainWindow")
    }

    private var watchThumbnailPrefetchKey: String {
        let visibleTopics = store.visibleWatchTopicIds.map(String.init).joined(separator: ",")
        return "\(store.pageDisplayMode.rawValue)-\(store.watchPresentationMode.rawValue)-\(store.selectedTopicId ?? -1)-\(visibleTopics)-\(store.watchPoolVersion)"
    }

    private var savedThumbnailPrefetchKey: String {
        "\(store.pageDisplayMode.rawValue)-\(store.selectedTopicId ?? -1)"
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            if store.pageDisplayMode == .watchCandidates {
                Section("Watch Layout") {
                    ForEach(WatchPresentationMode.allCases, id: \.self) { mode in
                        Button {
                            store.setWatchPresentationMode(mode)
                        } label: {
                            if store.watchPresentationMode == mode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }

                Divider()
            }

            Section("Sort") {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        toggleSort(order)
                    } label: {
                        if displaySettings.sortOrder == order {
                            Label(order.label, systemImage: "checkmark")
                        } else {
                            Label(order.label, systemImage: order.sfSymbol)
                        }
                    }
                    .accessibilityIdentifier("sort\(order.label)")
                    .accessibilityLabel(order.accessibilityLabel)
                    .accessibilityValue(displaySettings.sortOrder == order ? "Active" : "Inactive")
                }

                Button {
                    displaySettings.sortOrder = nil
                } label: {
                    Label("Clear Sort", systemImage: "line.3.horizontal.decrease.circle")
                }
                .disabled(displaySettings.sortOrder == nil)
            }
        } label: {
            Label(sortMenuLabel, systemImage: sortMenuSymbol)
        }
        .help(sortMenuHelpText)
        .accessibilityIdentifier("sortMenu")
    }

    @ViewBuilder
    private var pageModeControls: some View {
        Picker("Page Mode", selection: Binding(
            get: { store.pageDisplayMode },
            set: { newMode in
                Task { @MainActor in
                    await store.activatePageDisplayMode(newMode)
                }
            }
        )) {
            Text("Saved").tag(TopicDisplayMode.saved)
            Text("Watch").tag(TopicDisplayMode.watchCandidates)
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
        .help("Switch between saved videos and watch discovery")
    }

    /// Persistent active-creator-filter chip shown via safeAreaInset(edge: .top)
    /// at the very top of the grid pane. Modeled on Mail's filter row chips
    /// (Unread, VIP, etc.) — stays visible while scrolling so the user always
    /// has both the active-filter signal and a one-click path to the
    /// dedicated detail page.
    ///
    /// Single insight, single row, no labels on buttons:
    ///
    ///   [avatar 36] Channel Name        [Top Theme]    [↗] [×]
    ///
    /// Click anywhere on the left side (avatar / name / theme) → opens the
    /// creator detail page. The chevron icon is a redundant explicit click
    /// target. The × button clears the filter.
    @ViewBuilder
    private var creatorFilterChip: some View {
        if let channelId = store.selectedChannelId,
           let channel = creatorFilterChannelRecord(channelId: channelId) {
            HStack(spacing: 12) {
                Button {
                    store.openCreatorDetail(channelId: channelId)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        creatorFilterAvatar(channel)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                        Text(channel.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let topTheme = creatorFilterTopTheme(channelId: channelId) {
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
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the creator page for \(channel.name)")
                .accessibilityIdentifier("creatorFilterPreview")

                Button {
                    store.openCreatorDetail(channelId: channelId)
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Open the creator page for \(channel.name)")
                .accessibilityIdentifier("creatorFilterOpenDetail")

                Button {
                    store.selectedChannelId = nil
                    store.inspectedCreatorName = nil
                    store.selectedVideoId = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the creator filter")
                .accessibilityIdentifier("creatorFilterClear")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(.quaternary),
                alignment: .bottom
            )
        }
    }

    /// O(1) lookup of a channel record by id from the topic-channels cache
    /// the store already maintains. Avoids hitting SQLite from a view body.
    private func creatorFilterChannelRecord(channelId: String) -> ChannelRecord? {
        for channels in store.topicChannels.values {
            if let match = channels.first(where: { $0.channelId == channelId }) {
                return match
            }
        }
        return nil
    }

    /// Top LLM theme label for a creator from the creator_themes cache.
    /// Returns nil when the creator hasn't been classified yet.
    private func creatorFilterTopTheme(channelId: String) -> String? {
        guard let themes = try? store.store.creatorThemes(channelId: channelId),
              !themes.isEmpty else {
            return nil
        }
        return themes
            .sorted { $0.videoIds.count > $1.videoIds.count }
            .first?.label
    }

    @ViewBuilder
    private func creatorFilterAvatar(_ channel: ChannelRecord) -> some View {
        if let data = channel.iconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let urlString = channel.iconUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.accentColor.opacity(0.25)
            }
        } else {
            Color.accentColor.opacity(0.25)
                .overlay(
                    Text(channel.name.prefix(1))
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                )
        }
    }

    @ViewBuilder
    private var statusIndicators: some View {
        if let playlistTitle = store.selectedPlaylistTitle {
            Button {
                store.clearPlaylistFilter()
                displaySettings.toast.show("Playlist Filter Cleared", icon: "music.note.list")
            } label: {
                Label(playlistTitle, systemImage: "music.note.list")
            }
            .buttonStyle(.bordered)
            .help("Clear playlist filter")
        }

        if store.isLoading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading")
        }

        if store.youtubeQuotaExhausted {
            Label("API Quota Exhausted", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .help("YouTube API daily quota exceeded. Some features are limited until midnight Pacific time.")
        }

        scrapeHealthIndicator

        if thumbnailCache.isDownloading {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("\(thumbnailCache.downloadedCount)/\(thumbnailCache.totalCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Downloading thumbnails: \(thumbnailCache.downloadedCount) of \(thumbnailCache.totalCount)")
        }
    }

    /// Phase 3: scrape health pill in the toolbar. Hidden when state is healthy
    /// or unknown (no recent attempts) — only surfaces when there's something
    /// to flag. Click to open Settings (where the discovery section can show
    /// recent failures and let the user clear/retry). Tooltip shows the actual
    /// failure reason and how many of the recent N attempts failed.
    @ViewBuilder
    private var scrapeHealthIndicator: some View {
        if let health = store.scrapeHealth, health.state == .degraded || health.state == .blocked {
            let icon = health.state == .blocked ? "wifi.exclamationmark" : "exclamationmark.triangle"
            let color: Color = health.state == .blocked ? .red : .orange
            let label = health.state == .blocked ? "Scrape Blocked" : "Scrape Degraded"
            Button {
                openSettings()
            } label: {
                Label(label, systemImage: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
            }
            .buttonStyle(.borderless)
            .help(scrapeHealthTooltip(health))
            .accessibilityIdentifier("scrapeHealthIndicator")
        }
    }

    private func scrapeHealthTooltip(_ health: ScrapeHealthSnapshot) -> String {
        var parts: [String] = []
        parts.append("\(health.recentFailures) of \(health.recentAttempts) recent scrape\(health.recentAttempts == 1 ? "" : "s") failed (\(Int(health.failureRate * 100))%).")
        if let reason = health.suspectedReason {
            parts.append("Likely cause: \(reason).")
        }
        if let lastFailure = health.lastFailureMessage {
            parts.append("Most recent error: \(lastFailure)")
        }
        return parts.joined(separator: " ")
    }

    private func prefetchWatchThumbnailsIfNeeded() async {
        guard store.pageDisplayMode == .watchCandidates else { return }
        let videoIds: [String]
        switch store.watchPresentationMode {
        case .byTopic:
            let topicIds = store.visibleWatchTopicIds.isEmpty
                ? [store.selectedTopicId].compactMap { $0 }
                : store.visibleWatchTopicIds
            let visibleCandidates = topicIds.flatMap { store.candidateVideosForTopic($0) }
            videoIds = Array(
                Set(
                    visibleCandidates
                        .filter { !$0.isPlaceholder }
                        .map(\.videoId)
                )
            )
        case .allTogether:
            videoIds = Array(
                Set(
                    store.candidateVideosForAllTopics()
                        .filter { !$0.isPlaceholder }
                        .prefix(72)
                        .map(\.videoId)
                )
            )
        }
        guard !videoIds.isEmpty else { return }
        await thumbnailCache.prefetch(videoIds: videoIds)
    }

    private func prefetchSelectedSavedTopicThumbnailsIfNeeded() async {
        guard store.pageDisplayMode == .saved,
              let topicId = store.selectedTopicId else { return }
        let videoIds = Array(Set(
            store.videosForTopicIncludingSubtopics(topicId)
                .compactMap { $0.videoId.isEmpty ? nil : $0.videoId }
        ))
        guard !videoIds.isEmpty else { return }
        await thumbnailCache.prefetch(videoIds: videoIds)
    }

    private var sortMenuLabel: String {
        displaySettings.sortOrder?.label ?? "Sort"
    }

    private var sortMenuSymbol: String {
        displaySettings.sortOrder?.sfSymbol ?? "line.3.horizontal.decrease.circle"
    }

    private var sortMenuHelpText: String {
        if store.pageDisplayMode == .watchCandidates {
            return "Sort videos or choose the Watch layout"
        }
        return "Sort videos"
    }

    private func toggleSort(_ order: SortOrder) {
        if store.selectedChannelId != nil {
            store.clearChannelFilter()
            displaySettings.toast.show("Creator Filter Cleared", icon: "person.crop.circle.badge.xmark")
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            if displaySettings.sortOrder == order {
                if order == .shuffle {
                    displaySettings.sortAscending.toggle()
                } else {
                    displaySettings.sortOrder = nil
                }
            } else {
                displaySettings.sortOrder = order
                displaySettings.sortAscending = false
            }
        }
        displaySettings.toast.show(order.helpText, icon: order.sfSymbol)
    }
}

private struct TopicScrollProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
                    .animation(.easeOut(duration: GridConstants.progressAnimationDuration), value: progress)
            }
        }
        .frame(height: GridConstants.progressBarHeight)
        .background(.bar)
        .accessibilityLabel("Topic scroll progress")
        .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent")
    }
}
