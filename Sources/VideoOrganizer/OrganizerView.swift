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

    /// False when the sidebar would only display topics the user can't
    /// interact with (Watch + Show All ignores topic selection). True in
    /// every other mode combination.
    private var sidebarIsFunctional: Bool {
        !(store.pageDisplayMode == .watchCandidates
          && store.watchPresentationMode == .allTogether)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TopicSidebar(store: store, displaySettings: displaySettings, thumbnailCache: thumbnailCache)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            NavigationStack(path: $store.detailPath) {
                CollectionGridView(store: store, thumbnailCache: thumbnailCache, displaySettings: displaySettings)
                    .navigationTitle("")
                    .safeAreaInset(edge: .top, spacing: 0) {
                        gridHeaderRow
                    }
                    .inspector(isPresented: $displaySettings.showInspector) {
                        VideoInspector(store: store, thumbnailCache: thumbnailCache, displaySettings: displaySettings)
                            .inspectorColumnWidth(min: 296, ideal: 320, max: 344)
                            .accessibilityIdentifier("videoInspector")
                    }
                    .toolbar {
                        // Three-thing toolbar after the design simplification:
                        // pageModeControls on the left, Inspector on the right.
                        // Sort moved to the grid header (next to the active topic
                        // title) and status indicators moved to the sidebar
                        // footer — see the design plan in
                        // docs/creator-detail-removed-features.md for context.
                        ToolbarItemGroup(placement: .automatic) {
                            pageModeControls
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
                    columnVisibility = sidebarIsFunctional ? .all : .detailOnly
                } else {
                    columnVisibility = .detailOnly
                }
            }
            .onChange(of: sidebarIsFunctional) { _, newValue in
                // Watch + Show All ignores topic selection, so the topic rail
                // is just visual weight. Auto-collapse when entering that combo,
                // restore when leaving. User can still override with ⌘0.
                guard store.detailPath.isEmpty else { return }
                columnVisibility = newValue ? .all : .detailOnly
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

    private var selectedCreatorChannel: ChannelRecord? {
        guard let selectedChannelId = store.selectedChannelId else { return nil }
        if let selectedTopicId = store.selectedTopicId,
           let topicMatch = store.channelsForTopic(selectedTopicId).first(where: { $0.channelId == selectedChannelId }) {
            return topicMatch
        }
        return store.knownChannelsById[selectedChannelId] ?? (try? store.store.channelById(selectedChannelId))
    }

    /// Header pinned to the top of the grid pane via `safeAreaInset(.top)`.
    /// Two-row layout when a creator filter is active:
    ///
    ///   Row 1 (filter row, only when filter is active): full-width
    ///         edge-to-edge banner with avatar + name + subscribers,
    ///         a primary blue "Open Creator Page" CTA, and an X clear.
    ///   Row 2 (sort row, always visible): sort menu, right-aligned.
    ///
    /// Both rows share a single `.bar` material background so they read
    /// as a unified header. When no filter is active, only the sort row
    /// renders (~28pt total chrome).
    @ViewBuilder
    private var gridHeaderRow: some View {
        VStack(spacing: 0) {
            if let channel = selectedCreatorChannel {
                ActiveCreatorFilterCard(
                    channel: channel,
                    onOpenDetail: {
                        store.openCreatorDetail(channelId: channel.channelId)
                    },
                    onClear: {
                        store.clearChannelFilter()
                        displaySettings.toast.show("Creator Filter Cleared", icon: "person.crop.circle.badge.xmark")
                    }
                )
                Divider()
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                sortMenu
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                if store.pageDisplayMode == .watchCandidates {
                    Button {
                        store.ensureCandidatesForWatchPage()
                        displaySettings.toast.show("Refreshing Watch", icon: "arrow.clockwise")
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Refresh Watch candidates from all topics")
                    .disabled(store.candidateLoadingTopics.count > 0)
                }
            }
            .padding(.horizontal, GridConstants.horizontalPadding)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.quaternary),
            alignment: .bottom
        )
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

    // Status indicators (playlist filter, loading, quota, scrape health,
    // thumbnail download progress) used to live here as a toolbar group.
    // They moved to TopicSidebar's `statusFooter` in the design pass —
    // ambient status belongs in a status bar pinned to the bottom of the
    // sidebar, not in the chrome that frames primary actions.

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

/// Edge-to-edge filter banner shown above the grid when a creator filter
/// is active. Lives in the top safeAreaInset alongside the sort row, with
/// a shared `.bar` material background. The card itself has no rounded
/// chrome — it's a flat horizontal band.
///
/// Layout: `[avatar 56] [name + subscribers] Spacer [Open Creator Page] [×]`.
/// The blue button is the primary CTA. The X is a tertiary clear.
private struct ActiveCreatorFilterCard: View {
    let channel: ChannelRecord
    let onOpenDetail: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ChannelIconView(
                iconData: channel.iconData,
                fallbackUrl: channel.iconUrl.flatMap(URL.init(string:))
            )
            .frame(width: 56, height: 56)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(channel.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if channel.subscriberCount != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }

                if let subscriberLabel = subscriberLabel {
                    Text(subscriberLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                onOpenDetail()
            } label: {
                Label("Open Creator Page", systemImage: "chevron.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("Open the full creator detail page for \(channel.name)")
            .accessibilityIdentifier("openCreatorPageFromFilterCard")

            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Clear creator filter")
        }
        .padding(.horizontal, GridConstants.horizontalPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subscriberLabel: String? {
        guard let raw = channel.subscriberCount, let count = Int(raw) else { return nil }
        if count >= 1_000_000 {
            return String(format: "%.2fM subscribers", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fK subscribers", Double(count) / 1_000)
        }
        return "\(count) subscribers"
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
