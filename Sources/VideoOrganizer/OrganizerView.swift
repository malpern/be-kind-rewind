import SwiftUI

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
                .overlay(alignment: .top) {
                    if let overlay = store.candidateProgressOverlay {
                        CandidateProgressOverlayView(state: overlay)
                            .padding(.top, 20)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
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
        .alert(item: $store.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task(id: watchThumbnailPrefetchKey) {
            await prefetchWatchThumbnailsIfNeeded()
        }
        .accessibilityIdentifier("mainWindow")
    }

    private var watchThumbnailPrefetchKey: String {
        "\(store.pageDisplayMode.rawValue)-\(store.candidateRefreshToken)"
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
        let videoIds = Array(Set(store.candidateVideosForAllTopics().map(\.videoId)))
        guard !videoIds.isEmpty else { return }
        await thumbnailCache.prefetch(videoIds: videoIds)
    }
}

private struct CandidateProgressOverlayView: View {
    let state: CandidateProgressOverlayState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Finding Watch Videos", systemImage: "sparkles")
                    .font(.headline.weight(.semibold))

                Spacer(minLength: 0)

                Text(state.topicName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ProgressView(value: min(max(state.progress, 0), 1), total: 1)
                .progressViewStyle(.linear)
                .controlSize(.small)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 0)

                Text("\(Int((min(max(state.progress, 0), 1) * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
        .allowsHitTesting(false)
    }
}
