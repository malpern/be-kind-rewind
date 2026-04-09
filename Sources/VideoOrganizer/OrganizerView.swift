import SwiftUI

/// Root three-column layout: topic sidebar, collection grid, and optional inspector.
struct OrganizerView: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache
    @Bindable var displaySettings: DisplaySettings

    var body: some View {
        NavigationSplitView {
            TopicSidebar(store: store, displaySettings: displaySettings)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            CollectionGridView(store: store, thumbnailCache: thumbnailCache, displaySettings: displaySettings)
                .navigationTitle("")
                .safeAreaInset(edge: .top, spacing: 0) {
                    if store.selectedTopicId != nil,
                       (store.pageDisplayMode == .saved
                        || (store.pageDisplayMode == .watchCandidates && store.watchPresentationMode == .byTopic)) {
                        TopicScrollProgressBar(progress: store.topicScrollProgress)
                    }
                }
                .overlay(alignment: .top) {
                    if store.watchRefreshTotalTopics > 0 {
                        WatchRefreshPill(
                            completed: store.watchRefreshCompletedTopics,
                            total: store.watchRefreshTotalTopics,
                            currentTopicName: store.watchRefreshCurrentTopicName
                        )
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .animation(.easeInOut(duration: 0.3), value: store.watchRefreshTotalTopics)
                    }
                }
                .inspector(isPresented: $displaySettings.showInspector) {
                    VideoInspector(store: store, thumbnailCache: thumbnailCache, displaySettings: displaySettings)
                        .inspectorColumnWidth(min: 280, ideal: 300, max: 340)
                        .accessibilityIdentifier("videoInspector")
                }
                .toolbar {
                    ToolbarItemGroup(placement: .automatic) {
                        pageModeControls
                    }

                    ToolbarItemGroup(placement: .automatic) {
                        sortButtons
                    }

                    ToolbarItemGroup(placement: .automatic) {
                        statusIndicators
                    }

                    ToolbarItem(placement: .primaryAction) {
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
        }
        .overlay(alignment: .top) {
            ActionToast(state: displaySettings.toast)
                .padding(.top, 4)
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
    private var sortButtons: some View {
        if store.pageDisplayMode == .watchCandidates {
            Picker("Watch Layout", selection: Binding(
                get: { store.watchPresentationMode },
                set: { store.setWatchPresentationMode($0) }
            )) {
                ForEach(WatchPresentationMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .help("Choose how Watch videos are shown")
        }

        ForEach(SortOrder.allCases, id: \.self) { order in
            Button {
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
            } label: {
                Label(order.label, systemImage: order.sfSymbol)
            }
            .foregroundStyle(displaySettings.sortOrder == order ? Color.accentColor : .secondary)
            .help(order.helpText)
            .accessibilityIdentifier("sort\(order.label)")
            .accessibilityLabel(order.accessibilityLabel)
            .accessibilityValue(displaySettings.sortOrder == order ? "Active" : "Inactive")
        }
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


        if thumbnailCache.isDownloading {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("\(thumbnailCache.downloadedCount)/\(thumbnailCache.totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Downloading thumbnails: \(thumbnailCache.downloadedCount) of \(thumbnailCache.totalCount)")
        }
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

private struct WatchRefreshPill: View {
    let completed: Int
    let total: Int
    let currentTopicName: String?

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)

            Text("Refreshing \(completed)/\(total)")
                .font(.caption.monospacedDigit().weight(.medium))

            if let name = currentTopicName {
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .allowsHitTesting(false)
        .accessibilityLabel("Refreshing Watch candidates: \(completed) of \(total) topics")
    }
}

