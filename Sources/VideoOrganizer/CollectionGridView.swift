// CollectionGridView.swift
//
// High-performance video grid built on NSCollectionView, bridged into SwiftUI.
//
// Architecture:
//   CollectionGridView (SwiftUI)
//     └─ CollectionGridNSViewRepresentable (NSViewRepresentable)
//          └─ Coordinator (NSCollectionViewDataSource & Delegate)
//               └─ GridContainerView (NSView — owns scroll view + collection view)
//                    ├─ GridCell (NSCollectionViewItem, hosts SwiftUI GridCellContent)
//                    ├─ GridHeaderView (NSView, hosts SwiftUI GridHeaderContent)
//                    └─ FocusableCollectionView (NSCollectionView subclass — keyboard nav)
//
// Data flow:
//   1. Store state changes trigger .onChange → loadAndFilter()
//   2. GridSectionBuilder produces [TopicSection] from the store
//   3. Sections are passed to the Coordinator via representable update
//   4. Coordinator diffs and applies animated batch updates to NSCollectionView
//   5. Each cell hosts a lightweight SwiftUI view via NSHostingView

import SwiftUI
import AppKit
import TaggingKit

// MARK: - SwiftUI Wrapper

/// Top-level SwiftUI view wrapping the AppKit-backed collection grid.
struct CollectionGridView: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache
    @Bindable var displaySettings: DisplaySettings

    @State private var sections: [TopicSection] = []
    @State private var sectionGeneration: Int = 0

    var body: some View {
        CollectionGridRepresentable(
            store: store,
            sections: sections,
            sectionGeneration: sectionGeneration,
            cacheDir: thumbnailCache.cacheDirURL,
            thumbnailSize: displaySettings.thumbnailSize,
            showMetadata: displaySettings.showMetadata,
            selectedVideoId: store.selectedVideoId,
            selectedVideoIds: store.selectedVideoIds,
            scrollToTopicRequested: displaySettings.scrollToTopicRequested,
            scrollToSectionRequested: displaySettings.scrollToSectionRequested,
            focusGridRequested: displaySettings.focusGridRequested,
            onSelect: { videoId in
                store.selectedVideoId = videoId
            },
            onSelectionChange: { primary, ids in
                store.updateSelection(primary: primary, all: ids)
            },
            onClearTopicScrollRequest: {
                displaySettings.scrollToTopicRequested = nil
            },
            onClearSectionScrollRequest: {
                displaySettings.scrollToSectionRequested = nil
            },
            onClearGridFocusRequest: {
                displaySettings.focusGridRequested = false
            }
        )
        .task {
            loadAndFilter()
            if store.selectedVideoId == nil,
               let first = sections.lazy.flatMap(\.videos).first(where: { !$0.isPlaceholder }) {
                store.selectedVideoId = first.id
            }
        }
        .onChange(of: store.topics) { _, _ in loadAndFilter() }
        .onChange(of: store.searchText) { _, _ in loadAndFilter() }
        .onChange(of: displaySettings.sortOrder) { _, newValue in
            if newValue != .creator {
                store.inspectedCreatorName = nil
            }
            loadAndFilter()
        }
        .onChange(of: displaySettings.sortAscending) { _, _ in loadAndFilter() }
        .onChange(of: store.selectedSubtopicId) { _, _ in loadAndFilter() }
        .onChange(of: store.selectedChannelId) { _, _ in loadAndFilter() }
        .onChange(of: store.selectedPlaylistId) { _, _ in loadAndFilter() }
        .onChange(of: store.pageDisplayMode) { _, _ in loadAndFilter() }
        .onChange(of: store.watchPresentationMode) { _, _ in loadAndFilter() }
        .onChange(of: store.candidateRefreshToken) { _, _ in
            if store.pageDisplayMode != .watchCandidates {
                loadAndFilter()
            }
        }
        .onChange(of: store.watchPoolVersion) { _, _ in loadAndFilter() }
    }

    private func loadAndFilter() {
        let startedAt = ContinuousClock.now
        let result = GridSectionBuilder.build(
            context: GridSectionBuilder.Context(
                topics: store.topics,
                parsedQuery: store.parsedQuery,
                selectedSubtopicId: store.selectedSubtopicId,
                selectedTopicId: store.selectedTopicId,
                selectedChannelId: store.selectedChannelId,
                selectedPlaylistId: store.selectedPlaylistId,
                sortOrder: displaySettings.sortOrder,
                sortAscending: displaySettings.sortAscending,
                channelCounts: store.channelCounts,
                pageDisplayMode: store.pageDisplayMode,
                watchPresentationMode: store.watchPresentationMode,
                displayModeForTopic: { store.displayMode(for: $0) },
                videosForTopic: { topicId, displayMode in
                    videosForTopic(topicId, displayMode: displayMode)
                },
                videosForSubtopic: { subtopicId in
                    mapVideos(store.videosForTopic(subtopicId))
                },
                allWatchVideos: {
                    store.candidateVideosForAllTopics().map { candidate in
                        VideoGridItemModel(
                            id: candidate.videoId,
                            topicId: candidate.topicId,
                            title: candidate.title,
                            channelName: candidate.channelName,
                            topicName: store.topics.first(where: { $0.id == candidate.topicId })?.name,
                            thumbnailUrl: candidate.thumbnailUrl,
                            viewCount: candidate.viewCount,
                            publishedAt: candidate.publishedAt,
                            duration: candidate.duration,
                            channelIconUrl: candidate.channelIconUrl.flatMap(URL.init(string:)),
                            channelId: candidate.channelId,
                            candidateScore: candidate.score,
                            stateTag: store.badgeTagForVideo(
                                candidate.videoId,
                                candidateState: candidate.state,
                                topicId: candidate.topicId,
                                channelId: candidate.channelId
                            ),
                            isPlaceholder: false,
                            placeholderMessage: candidate.secondaryText
                        )
                    }
                },
                videoIsInSelectedPlaylist: { store.videoIsInSelectedPlaylist($0) }
            )
        )

        let sectionsChanged = result.sections != sections
        let searchCountChanged = result.searchResultCount != store.searchResultCount

        if searchCountChanged {
            store.searchResultCount = result.searchResultCount
        }

        if sectionsChanged {
            sections = result.sections
            sectionGeneration += 1
        }
        let duration = startedAt.duration(to: .now)
        AppLogger.discovery.debug(
            "loadAndFilter mode=\(self.store.pageDisplayMode.rawValue, privacy: .public) watchMode=\(self.store.watchPresentationMode.rawValue, privacy: .public) sections=\(result.sections.count, privacy: .public) results=\(result.searchResultCount, privacy: .public) changed=\(sectionsChanged, privacy: .public) in \(duration.formatted(.units(allowed: [.milliseconds], width: .narrow)), privacy: .public)"
        )
    }

    private func mapVideos(_ viewModels: [VideoViewModel]) -> [VideoGridItemModel] {
        viewModels.map { v in
            VideoGridItemModel(
                id: v.videoId, topicId: v.topicId, title: v.title, channelName: v.channelName,
                topicName: store.topicNameForVideo(v.videoId),
                thumbnailUrl: v.thumbnailUrl, viewCount: v.viewCount,
                publishedAt: v.publishedAt, duration: v.duration,
                channelIconUrl: v.channelIconUrl.flatMap { URL(string: $0) },
                channelId: v.channelId,
                candidateScore: nil,
                stateTag: store.badgeTagForVideo(v.videoId),
                isPlaceholder: false,
                placeholderMessage: nil
            )
        }
    }

    private func videosForTopic(_ topicId: Int64, displayMode: TopicDisplayMode) -> [VideoGridItemModel] {
        switch displayMode {
        case .saved:
            return mapVideos(store.videosForTopic(topicId))
        case .watchCandidates:
            return store.candidateVideosForTopic(topicId).map {
                VideoGridItemModel(
                    id: $0.videoId,
                    topicId: $0.topicId,
                    title: $0.title,
                    channelName: $0.channelName,
                    topicName: store.topics.first(where: { $0.id == topicId })?.name,
                    thumbnailUrl: $0.thumbnailUrl,
                    viewCount: $0.viewCount,
                    publishedAt: $0.publishedAt,
                    duration: $0.duration,
                    channelIconUrl: $0.channelIconUrl.flatMap(URL.init(string:)),
                    channelId: $0.channelId,
                    candidateScore: $0.score,
                    stateTag: store.badgeTagForVideo(
                        $0.videoId,
                        candidateState: $0.state,
                        topicId: $0.topicId,
                        channelId: $0.channelId
                    ),
                    isPlaceholder: $0.isPlaceholder,
                    placeholderMessage: $0.secondaryText
                )
            }
        }
    }

}

// MARK: - NSViewRepresentable

private struct CollectionGridRepresentable: NSViewRepresentable {
    let store: OrganizerStore
    let sections: [TopicSection]
    let sectionGeneration: Int
    let cacheDir: URL
    let thumbnailSize: Double
    let showMetadata: Bool
    let selectedVideoId: String?
    let selectedVideoIds: Set<String>
    let scrollToTopicRequested: Int64?
    let scrollToSectionRequested: String?
    let focusGridRequested: Bool
    let onSelect: (String) -> Void
    let onSelectionChange: (String?, Set<String>) -> Void
    let onClearTopicScrollRequest: () -> Void
    let onClearSectionScrollRequest: () -> Void
    let onClearGridFocusRequest: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelect: onSelect,
            onSelectionChange: onSelectionChange,
            onClearTopicScrollRequest: onClearTopicScrollRequest,
            onClearSectionScrollRequest: onClearSectionScrollRequest,
            onClearGridFocusRequest: onClearGridFocusRequest
        )
    }

    func makeNSView(context: Context) -> CollectionGridContainerView {
        let container = CollectionGridContainerView()
        context.coordinator.attach(to: container)
        return container
    }

    func updateNSView(_ container: CollectionGridContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.attach(to: container)
        coordinator.applySnapshot(
            store: store,
            sections: sections,
            generation: sectionGeneration,
            cacheDir: cacheDir,
            thumbnailSize: thumbnailSize,
            showMetadata: showMetadata,
            selectedVideoId: selectedVideoId,
            selectedVideoIds: selectedVideoIds,
            onSelect: onSelect
        )

        if let topicId = scrollToTopicRequested {
            coordinator.enqueueScroll(to: topicId)
        }

        if let sectionId = scrollToSectionRequested {
            coordinator.enqueueScroll(toSectionId: sectionId)
        }

        if focusGridRequested {
            coordinator.enqueueFocusRequest()
        }

        container.scheduleFlushIfReady()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
        private weak var container: CollectionGridContainerView?
        private weak var collectionView: NSCollectionView?

        private var store: OrganizerStore?
        private var pendingSections: [TopicSection] = []
        private var renderedSections: [TopicSection] = []
        private var pendingGeneration: Int = -1
        private var renderedGeneration: Int = -1
        private var pendingScrollTopicId: Int64?
        private var pendingScrollSectionId: String?
        private var pendingSelectedVideoId: String?
        private var renderedSelectedVideoId: String?
        private var pendingSelectedVideoIds: Set<String> = []
        private var renderedSelectedVideoIds: Set<String> = []
        private var needsLayoutInvalidation = false
        private var renderedContentWidth: CGFloat = 0
        private var isApplyingSelectionToCollectionView = false
        private var pendingFocusGridRequest = false
        private var actionObservers: [NSObjectProtocol] = []
        private var scrollFeedbackUpdateScheduled = false

        var cacheDir: URL = URL(fileURLWithPath: "/tmp")
        var thumbnailSize: Double = 220
        var showMetadata: Bool = true
        var onSelect: (String) -> Void
        var onSelectionChange: (String?, Set<String>) -> Void
        var onClearTopicScrollRequest: () -> Void
        var onClearSectionScrollRequest: () -> Void
        var onClearGridFocusRequest: () -> Void

        init(
            onSelect: @escaping (String) -> Void,
            onSelectionChange: @escaping (String?, Set<String>) -> Void,
            onClearTopicScrollRequest: @escaping () -> Void,
            onClearSectionScrollRequest: @escaping () -> Void,
            onClearGridFocusRequest: @escaping () -> Void
        ) {
            self.onSelect = onSelect
            self.onSelectionChange = onSelectionChange
            self.onClearTopicScrollRequest = onClearTopicScrollRequest
            self.onClearSectionScrollRequest = onClearSectionScrollRequest
            self.onClearGridFocusRequest = onClearGridFocusRequest
        }

        func attach(to container: CollectionGridContainerView) {
            guard self.container !== container else { return }
            self.container = container
            self.collectionView = container.collectionView
            container.collectionView.dataSource = self
            container.collectionView.delegate = self
            container.collectionView.onDoubleClickItem = { [weak self] indexPath in
                self?.handleDoubleClick(at: indexPath)
            }
            container.collectionView.onContextMenuRequest = { [weak self] point in
                self?.menuForInteraction(at: point)
            }
            container.collectionView.onMarqueeSelection = { [weak self] rect, modifiers, finalize in
                self?.handleMarqueeSelection(in: rect, modifiers: modifiers, finalize: finalize)
            }
            container.collectionView.onSaveToWatchLaterShortcut = { [weak self] in
                self?.handleSaveToWatchLaterShortcut()
            }
            container.collectionView.onSaveToPlaylistShortcut = { [weak self] in
                self?.handleSaveToPlaylistShortcut()
            }
            container.collectionView.onMoveToPlaylistShortcut = { [weak self] in
                self?.handleMoveToPlaylistShortcut()
            }
            container.collectionView.onDismissShortcut = { [weak self] in
                self?.handleDismissShortcut()
            }
            container.collectionView.onNotInterestedShortcut = { [weak self] in
                self?.handleNotInterestedShortcut()
            }
            container.collectionView.onOpenSelectedShortcut = { [weak self] in
                self?.handleOpenSelectedShortcut()
            }
            container.collectionView.onClearSelectionShortcut = { [weak self] in
                self?.handleClearSelectionShortcut()
            }
            container.onReadyForFlush = { [weak self] in
                self?.flushIfReady()
            }
            container.onBoundsChanged = { [weak self] in
                self?.scheduleScrollFeedbackUpdate()
            }
            installActionObserversIfNeeded()
        }

        func applySnapshot(
            store: OrganizerStore,
            sections: [TopicSection],
            generation: Int,
            cacheDir: URL,
            thumbnailSize: Double,
            showMetadata: Bool,
            selectedVideoId: String?,
            selectedVideoIds: Set<String>,
            onSelect: @escaping (String) -> Void
        ) {
            self.onSelect = onSelect
            self.store = store
            self.cacheDir = cacheDir

            if pendingGeneration != generation {
                pendingSections = sections
                pendingGeneration = generation
            }

            if self.thumbnailSize != thumbnailSize || self.showMetadata != showMetadata {
                self.thumbnailSize = thumbnailSize
                self.showMetadata = showMetadata
                needsLayoutInvalidation = true
            }

            pendingSelectedVideoId = selectedVideoId
            pendingSelectedVideoIds = selectedVideoIds
        }

        func enqueueScroll(to topicId: Int64) {
            if pendingScrollTopicId != topicId {
                AppLogger.grid.debug("Queued topic scroll request for topic \(topicId, privacy: .public)")
            }
            pendingScrollTopicId = topicId
        }

        func enqueueScroll(toSectionId sectionId: String) {
            if pendingScrollSectionId != sectionId {
                AppLogger.grid.debug("Queued section scroll request for \(sectionId, privacy: .public)")
            }
            pendingScrollSectionId = sectionId
        }

        func enqueueFocusRequest() {
            guard !pendingFocusGridRequest else { return }
            pendingFocusGridRequest = true
            AppLogger.grid.debug("Queued focus request for collection grid")
        }

        func flushIfReady() {
            guard let container, let collectionView, container.isReadyForCollectionWork else { return }
            let startedAt = ContinuousClock.now

            let shouldReload = renderedGeneration != pendingGeneration
            let currentContentWidth = container.scrollView.contentView.bounds.width
            let widthChanged = abs(currentContentWidth - renderedContentWidth) > 0.5
            if shouldReload {
                renderedSections = pendingSections
                renderedGeneration = pendingGeneration
                collectionView.reloadData()
            }

            let shouldInvalidateLayout = needsLayoutInvalidation || widthChanged
            if shouldInvalidateLayout {
                needsLayoutInvalidation = false
                renderedContentWidth = currentContentWidth
                container.flowLayout.invalidateLayout()
            }

            if shouldReload || shouldInvalidateLayout {
                collectionView.layoutSubtreeIfNeeded()
            }

            var didApplyScroll = false
            if let topicId = pendingScrollTopicId {
                if scrollToTopic(topicId) {
                    pendingScrollTopicId = nil
                    didApplyScroll = true
                    DispatchQueue.main.async { [onClearTopicScrollRequest] in
                        onClearTopicScrollRequest()
                    }
                }
            }

            if let sectionId = pendingScrollSectionId {
                if scrollToSection(sectionId) {
                    pendingScrollSectionId = nil
                    didApplyScroll = true
                    DispatchQueue.main.async { [onClearSectionScrollRequest] in
                        onClearSectionScrollRequest()
                    }
                }
            }

            if pendingFocusGridRequest, applyFocusIfPossible() {
                pendingFocusGridRequest = false
                DispatchQueue.main.async { [onClearGridFocusRequest] in
                    onClearGridFocusRequest()
                }
            }

            if renderedSelectedVideoId != pendingSelectedVideoId || renderedSelectedVideoIds != pendingSelectedVideoIds || shouldReload || shouldInvalidateLayout || didApplyScroll {
                renderedSelectedVideoId = pendingSelectedVideoId
                renderedSelectedVideoIds = pendingSelectedVideoIds
                applySelectionToCollectionView()
                refreshVisibleItems()
            }

            if shouldReload || shouldInvalidateLayout || didApplyScroll {
                refreshVisibleHeaders()
            }

            refreshTopicScrollProgress()
            refreshViewportContext()

            let duration = startedAt.duration(to: .now)
            let millis = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
            if millis >= 20 {
                AppLogger.discovery.debug(
                    "flushIfReady reload=\(shouldReload, privacy: .public) invalidate=\(shouldInvalidateLayout, privacy: .public) scroll=\(didApplyScroll, privacy: .public) sections=\(self.renderedSections.count, privacy: .public) took \(Int(millis), privacy: .public)ms"
                )
            }
        }

        // MARK: Data Source

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            renderedSections.count
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            guard section < renderedSections.count else { return 0 }
            return renderedSections[section].videos.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            guard let cell = collectionView.makeItem(withIdentifier: VideoItemCell.identifier, for: indexPath) as? VideoItemCell else {
                return VideoItemCell()
            }
            configure(cell: cell, at: indexPath)
            return cell
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            guard let header = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: CollectionSectionHeaderView.reuseIdentifier,
                for: indexPath
            ) as? CollectionSectionHeaderView else {
                return CollectionSectionHeaderView(frame: .zero)
            }
            guard indexPath.section < renderedSections.count else { return header }
            header.configure(model: headerModel(for: renderedSections[indexPath.section]))
            return header
        }

        // MARK: Delegate

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionFromCollectionView()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionFromCollectionView()
        }

        private func handleDoubleClick(at indexPath: IndexPath) {
            guard indexPath.section < renderedSections.count,
                  indexPath.item < renderedSections[indexPath.section].videos.count else { return }
            let video = renderedSections[indexPath.section].videos[indexPath.item]
            guard !video.isPlaceholder else { return }
            openOnYouTube(video)
        }

        // MARK: Layout

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            let spacing = showMetadata ? GridConstants.metadataGridSpacing : GridConstants.compactGridSpacing
            let containerWidth = collectionView.enclosingScrollView?.contentView.bounds.width ?? 0
            let usableWidth = max(containerWidth - (GridConstants.horizontalPadding * 2), CGFloat(thumbnailSize))
            let targetWidth = max(CGFloat(thumbnailSize), 1)
            let columnCount = max(1, Int((usableWidth + spacing) / (targetWidth + spacing)))
            let totalSpacing = spacing * CGFloat(columnCount - 1)
            let itemWidth = floor((usableWidth - totalSpacing) / CGFloat(columnCount))
            let thumbnailHeight = itemWidth * 9.0 / 16.0
            let metadataHeight: CGFloat = showMetadata ? 82 : 28
            return NSSize(width: itemWidth, height: thumbnailHeight + metadataHeight)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            insetForSectionAt section: Int
        ) -> NSEdgeInsets {
            NSEdgeInsets(
                top: 0,
                left: GridConstants.horizontalPadding,
                bottom: GridConstants.sectionBottomPadding,
                right: GridConstants.horizontalPadding
            )
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            minimumLineSpacingForSectionAt section: Int
        ) -> CGFloat {
            showMetadata ? GridConstants.metadataGridSpacing : GridConstants.compactGridSpacing
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            minimumInteritemSpacingForSectionAt section: Int
        ) -> CGFloat {
            showMetadata ? GridConstants.metadataGridSpacing : GridConstants.compactGridSpacing
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> NSSize {
            guard renderedSections.indices.contains(section) else {
                return NSSize(width: max(collectionView.bounds.width, 1), height: 48)
            }
            let height = headerHeight(for: renderedSections[section])
            return NSSize(width: max(collectionView.bounds.width, 1), height: height)
        }

        // MARK: Helpers

        private func configure(cell: VideoItemCell, at indexPath: IndexPath) {
            guard indexPath.section < renderedSections.count,
                  indexPath.item < renderedSections[indexPath.section].videos.count else { return }

            let video = renderedSections[indexPath.section].videos[indexPath.item]
            cell.representedIndexPath = indexPath
            cell.onHoverChange = { [weak self] hovering in
                self?.handleHoverChange(for: video, hovering: hovering)
            }
            cell.onContextMenuRequest = { [weak self, weak cell] point in
                guard let self, let cell, let collectionView = self.collectionView else { return nil }
                let pointInCollection = collectionView.convert(point, from: cell.view)
                return self.menuForInteraction(at: pointInCollection)
            }
            cell.configure(
                video: video,
                cacheDir: cacheDir,
                thumbnailSize: thumbnailSize,
                showMetadata: showMetadata,
                isSelected: renderedSelectedVideoIds.contains(video.id),
                highlightTerms: store?.parsedQuery.includeTerms ?? []
            )
        }

        private func applySelectionToCollectionView() {
            guard let collectionView else { return }
            isApplyingSelectionToCollectionView = true
            collectionView.deselectAll(nil)
            let selectedIndexPaths = Set(indexPaths(for: renderedSelectedVideoIds))
            if !selectedIndexPaths.isEmpty {
                collectionView.selectItems(at: selectedIndexPaths, scrollPosition: [])
            }
            isApplyingSelectionToCollectionView = false
        }

        private func syncSelectionFromCollectionView() {
            guard let collectionView, !isApplyingSelectionToCollectionView else { return }
            let selectedIndexPaths = collectionView.selectionIndexPaths
            let selectedVideos = selectedIndexPaths
                .sorted()
                .compactMap { video(at: $0) }
                .filter { !$0.isPlaceholder }
            let ids = Set(selectedVideos.map(\.id))
            let primary = selectedVideos.last?.id
            pendingSelectedVideoIds = ids
            renderedSelectedVideoIds = ids
            pendingSelectedVideoId = primary
            renderedSelectedVideoId = primary
            if let primary {
                onSelect(primary)
            } else {
                onSelectionChange(nil, Set<String>())
            }
            onSelectionChange(primary, ids)
            refreshVisibleItems()
        }

        private func refreshVisibleItems() {
            guard let collectionView else { return }
            for item in collectionView.visibleItems() {
                guard let cell = item as? VideoItemCell,
                      let indexPath = cell.representedIndexPath else { continue }
                configure(cell: cell, at: indexPath)
            }
        }

        private func handleHoverChange(for video: VideoGridItemModel, hovering: Bool) {
            guard !video.isPlaceholder else { return }
            guard let store else { return }

            if hovering {
                store.hoveredVideoId = video.id
            } else if store.hoveredVideoId == video.id {
                store.hoveredVideoId = nil
            }
        }

        private func applyFocusIfPossible() -> Bool {
            guard let collectionView, let window = collectionView.window else { return false }
            let accepted = window.makeFirstResponder(collectionView)
            if accepted {
                AppLogger.grid.debug("Focused collection grid")
            } else {
                AppLogger.grid.error("Failed to focus collection grid")
            }
            return accepted
        }

        @discardableResult
        private func scrollToTopic(_ topicId: Int64) -> Bool {
            guard let collectionView,
                  collectionView.numberOfSections > 0,
                  let sectionIndex = renderedSections.firstIndex(where: { $0.topicId == topicId }),
                  sectionIndex < collectionView.numberOfSections else {
                AppLogger.grid.debug("Deferring topic scroll for topic \(topicId, privacy: .public); section not ready")
                return false
            }

            return scrollToSectionIndex(sectionIndex)
        }

        @discardableResult
        private func scrollToSection(_ sectionId: String) -> Bool {
            guard let collectionView,
                  collectionView.numberOfSections > 0,
                  let sectionIndex = renderedSections.firstIndex(where: { $0.id == sectionId }),
                  sectionIndex < collectionView.numberOfSections else {
                AppLogger.grid.debug("Deferring section scroll for \(sectionId, privacy: .public); section not ready")
                return false
            }

            return scrollToSectionIndex(sectionIndex)
        }

        @discardableResult
        private func scrollToSectionIndex(_ sectionIndex: Int) -> Bool {
            guard let collectionView else { return false }
            let section = renderedSections[sectionIndex]
            let itemCount = collectionView.numberOfItems(inSection: sectionIndex)
            if itemCount > 0 {
                let indexPath = IndexPath(item: 0, section: sectionIndex)
                collectionView.scrollToItems(at: Set([indexPath]), scrollPosition: .top)
                AppLogger.grid.info(
                    "Scrolled to section \(section.id, privacy: .public) for topic \(section.topicId, privacy: .public)"
                )

                let video = renderedSections[sectionIndex].videos[0]
                if !video.isPlaceholder {
                    pendingSelectedVideoId = video.id
                    renderedSelectedVideoId = video.id
                    onSelect(video.id)
                }
                return true
            }

            guard let scrollView = collectionView.enclosingScrollView,
                  let attributes = collectionView.collectionViewLayout?
                    .layoutAttributesForSupplementaryView(
                        ofKind: NSCollectionView.elementKindSectionHeader,
                        at: IndexPath(item: 0, section: sectionIndex)
                    ) else { return false }

            let origin = NSPoint(x: 0, y: max(attributes.frame.minY, 0))
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            AppLogger.grid.info(
                "Scrolled to header-only section \(section.id, privacy: .public) for topic \(section.topicId, privacy: .public)"
            )

            if let nextVideoSection = renderedSections.dropFirst(sectionIndex + 1).first(where: { !$0.videos.isEmpty }),
               let video = nextVideoSection.videos.first {
                pendingSelectedVideoId = video.id
                renderedSelectedVideoId = video.id
                onSelect(video.id)
            }
            return true
        }

        private func headerModel(for section: TopicSection) -> CollectionSectionHeaderModel {
            let sectionIndex = renderedSections.firstIndex(where: { $0.id == section.id })
            return headerModel(for: section, at: sectionIndex)
        }

        private func headerHeight(for section: TopicSection) -> CGFloat {
            if section.creatorName != nil {
                return 56
            }

            let channels = headerChannels(for: section)
            return channels.isEmpty ? 48 : 112
        }

        private func headerModel(for section: TopicSection, at sectionIndex: Int?) -> CollectionSectionHeaderModel {
            let scrollProgress: Double
            if section.creatorName != nil || isTopicMarkerInCreatorGrouping(section) {
                scrollProgress = topicScrollProgress(forTopicId: section.topicId)
            } else {
                scrollProgress = sectionIndex.map(sectionScrollProgress(forSectionAt:)) ?? 0
            }

            if let creatorName = section.creatorName {
                return .creator(
                    channelName: creatorName,
                    channelIconUrl: section.channelIconUrl,
                    channelUrl: section.creatorChannelUrl,
                    count: section.videos.count,
                    totalCount: section.totalCount,
                    topicNames: section.topicNames,
                    sectionId: section.id,
                    scrollProgress: scrollProgress,
                    highlightTerms: store?.parsedQuery.includeTerms ?? [],
                    onInspect: { [weak store] in
                        _ = store?.navigateToCreator(channelId: section.creatorChannelId, channelName: creatorName, preferredTopicId: section.topicId)
                    }
                )
            }

            let highlightTerms = store?.parsedQuery.includeTerms ?? []
            let channels = headerChannels(for: section)
            let selectedChannelId = store?.selectedChannelId
            let watchCandidatesForSection = section.displayMode == .watchCandidates
                ? (section.topicId == -1
                    ? store?.recentCandidateVideosForAllTopics() ?? []
                    : store?.recentStoredCandidateVideosForTopic(section.topicId) ?? [])
                : []

            return .topic(
                name: section.topicName,
                count: section.headerCountOverride ?? section.videos.count,
                totalCount: section.totalCount,
                topicId: section.topicId,
                scrollProgress: scrollProgress,
                highlightTerms: highlightTerms,
                displayMode: section.displayMode,
                channels: channels,
                selectedChannelId: selectedChannelId,
                videoCountForChannel: { [weak store] channelId in
                    guard let store else { return 0 }
                    if section.displayMode == .watchCandidates {
                        let channel = channels.first(where: { $0.channelId == channelId })
                        return store.watchCandidateCountForChannel(
                            channel?.channelId ?? channelId,
                            channelName: channel?.name,
                            inCandidates: watchCandidatesForSection
                        )
                    }
                    return store.videoCountForChannel(channelId, inTopic: section.topicId)
                },
                hasRecentContent: { [weak store] channelId in
                    guard let store else { return false }
                    if section.displayMode == .watchCandidates {
                        let channel = channels.first(where: { $0.channelId == channelId })
                        return store.latestWatchCandidateDateForChannel(
                            channel?.channelId ?? channelId,
                            channelName: channel?.name,
                            inCandidates: watchCandidatesForSection
                        ) != nil
                    }
                    return store.channelHasRecentContent(channelId, inTopic: section.topicId)
                },
                latestPublishedAtForChannel: { [weak store] channelId in
                    guard let store else { return nil }
                    if section.displayMode == .watchCandidates {
                        let channel = channels.first(where: { $0.channelId == channelId })
                        return store.latestWatchCandidateDateForChannel(
                            channel?.channelId ?? channelId,
                            channelName: channel?.name,
                            inCandidates: watchCandidatesForSection
                        )
                    }
                    return self.latestSavedPublishedDateForChannel(channelId, topicId: section.topicId)
                },
                onSelectChannel: { [weak store] channelId in
                    guard let store else { return }
                    let channel = channels.first(where: { $0.channelId == channelId })
                    if section.displayMode == .watchCandidates {
                        _ = store.navigateToCreatorInWatch(channelId: channel?.channelId ?? channelId, channelName: channel?.name, preferredTopicId: section.topicId)
                    } else {
                        _ = store.navigateToCreator(channelId: channelId, channelName: channel?.name, preferredTopicId: section.topicId)
                    }
                }
            )
        }

        private func headerChannels(for section: TopicSection) -> [ChannelRecord] {
            guard let store else { return [] }
            if section.displayMode == .watchCandidates {
                return watchChannels(for: section)
            }
            return store.channelsForTopic(section.topicId)
        }

        private func watchChannels(for section: TopicSection) -> [ChannelRecord] {
            guard let store else { return [] }
            let sourceVideos: [CandidateVideoViewModel]
            if section.topicId == -1 {
                sourceVideos = store.watchPoolForAllTopics(applyingChannelFilter: false)
            } else {
                sourceVideos = store.watchPoolForTopic(section.topicId, applyingChannelFilter: false)
            }

            var bestByChannelId: [String: ChannelRecord] = [:]
            for video in sourceVideos where !video.isPlaceholder {
                let channelId = if let channelId = video.channelId, !channelId.isEmpty {
                    channelId
                } else {
                    "watch-\(video.channelName ?? "unknown")"
                }
                guard bestByChannelId[channelId] == nil else { continue }
                if let resolved = store.resolvedChannelRecord(
                    channelId: video.channelId,
                    fallbackName: video.channelName ?? "Unknown Creator",
                    fallbackIconURL: video.channelIconUrl
                ) {
                    bestByChannelId[channelId] = resolved
                }
            }

            return Array(bestByChannelId.values)
        }

        private func latestSavedPublishedDateForChannel(_ channelId: String, topicId: Int64) -> Date? {
            guard let store else { return nil }
            return store.videosForTopicIncludingSubtopics(topicId)
                .filter { $0.channelId == channelId }
                .compactMap { video in
                    guard let publishedAt = video.publishedAt else { return nil }
                    return parsedPublishedDate(from: publishedAt)
                }
                .max()
        }

        private func effectiveChannelKey(for video: VideoGridItemModel) -> String {
            if let channelId = video.channelId, !channelId.isEmpty {
                return channelId
            }
            return "watch-\(video.channelName ?? "unknown")"
        }

        private func parsedPublishedDate(from publishedAt: String) -> Date? {
            if let iso = CreatorAnalytics.parseISO8601Date(publishedAt) {
                return iso
            }
            let ageDays = CreatorAnalytics.parseAge(publishedAt)
            guard ageDays != .max else { return nil }
            return Calendar.current.date(byAdding: .day, value: -ageDays, to: Date())
        }

        private func isTopicMarkerInCreatorGrouping(_ section: TopicSection) -> Bool {
            section.creatorName == nil && renderedSections.contains { $0.topicId == section.topicId && $0.creatorName != nil }
        }

        private func topicScrollProgress(forTopicId topicId: Int64) -> Double {
            guard let collectionView,
                  let scrollView = collectionView.enclosingScrollView else { return 0 }

            let visibleBounds = scrollView.contentView.bounds
            guard visibleBounds.height > 0 else { return 0 }

            let sectionIndices = renderedSections.indices.filter { renderedSections[$0].topicId == topicId }
            guard !sectionIndices.isEmpty else { return 0 }

            var topicFrame: CGRect?
            for sectionIndex in sectionIndices {
                guard let sectionFrame = frameForSection(at: sectionIndex) else { continue }
                topicFrame = topicFrame.map { $0.union(sectionFrame) } ?? sectionFrame
            }

            guard let frame = topicFrame else { return 0 }
            let scrollableDistance = max(frame.height - visibleBounds.height, 1)
            let scrolled = visibleBounds.minY - frame.minY
            return min(max(scrolled / scrollableDistance, 0), 1)
        }

        private func sectionScrollProgress(forSectionAt sectionIndex: Int) -> Double {
            guard let collectionView,
                  let scrollView = collectionView.enclosingScrollView,
                  renderedSections.indices.contains(sectionIndex) else { return 0 }

            let visibleBounds = scrollView.contentView.bounds
            guard visibleBounds.height > 0 else { return 0 }

            guard let frame = frameForSection(at: sectionIndex) else { return 0 }
            let scrollableDistance = max(frame.height - visibleBounds.height, 1)
            let scrolled = visibleBounds.minY - frame.minY
            return min(max(scrolled / scrollableDistance, 0), 1)
        }

        private func frameForSection(at sectionIndex: Int) -> CGRect? {
            guard let collectionView else { return nil }

            let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
            var sectionFrame = collectionView.collectionViewLayout?.layoutAttributesForSupplementaryView(
                ofKind: NSCollectionView.elementKindSectionHeader,
                at: headerIndexPath
            )?.frame

            let itemCount = collectionView.numberOfItems(inSection: sectionIndex)
            if itemCount > 0,
               let firstItemFrame = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: sectionIndex))?.frame,
               let lastItemFrame = collectionView.layoutAttributesForItem(at: IndexPath(item: itemCount - 1, section: sectionIndex))?.frame {
                let itemsFrame = firstItemFrame.union(lastItemFrame)
                sectionFrame = sectionFrame.map { $0.union(itemsFrame) } ?? itemsFrame
            }

            return sectionFrame
        }

        private func refreshVisibleHeaders() {
            guard let collectionView else { return }
            let startedAt = ContinuousClock.now
            let visibleRect = collectionView.visibleRect
            var refreshedCount = 0
            for sectionIndex in renderedSections.indices {
                let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
                guard let attributes = collectionView.collectionViewLayout?.layoutAttributesForSupplementaryView(
                    ofKind: NSCollectionView.elementKindSectionHeader,
                    at: headerIndexPath
                ) else { continue }
                guard attributes.frame.intersects(visibleRect),
                      let header = collectionView.supplementaryView(
                        forElementKind: NSCollectionView.elementKindSectionHeader,
                        at: headerIndexPath
                      ) as? CollectionSectionHeaderView else { continue }
                header.configure(model: headerModel(for: renderedSections[sectionIndex], at: sectionIndex))
                refreshedCount += 1
            }
            let duration = startedAt.duration(to: .now)
            let millis = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
            if millis >= 12 {
                AppLogger.discovery.debug(
                    "refreshVisibleHeaders count=\(refreshedCount, privacy: .public) took \(Int(millis), privacy: .public)ms"
                )
            }
        }

        private func refreshTopicScrollProgress() {
            guard let store else { return }
            let supportsTopicProgress =
                store.pageDisplayMode == .saved ||
                (store.pageDisplayMode == .watchCandidates && store.watchPresentationMode == .byTopic)

            guard supportsTopicProgress,
                  let topicId = store.selectedTopicId else {
                if store.topicScrollProgress != 0 {
                    store.topicScrollProgress = 0
                }
                return
            }

            let progress = topicScrollProgress(forTopicId: topicId)
            if abs(store.topicScrollProgress - progress) > 0.001 {
                store.topicScrollProgress = progress
            }
        }

        private func refreshViewportContext() {
            let startedAt = ContinuousClock.now
            guard let store,
                  let collectionView,
                  let scrollView = collectionView.enclosingScrollView else {
                store?.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
                return
            }

            if store.pageDisplayMode == .watchCandidates {
                guard store.watchPresentationMode == .byTopic else {
                    store.updateVisibleWatchTopics([])
                    store.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
                    return
                }

                let visibleBounds = scrollView.contentView.bounds
                store.updateVisibleWatchTopics(visibleTopicIds(in: visibleBounds))
                guard let sectionIndex = primaryVisibleSectionIndex(in: visibleBounds) else {
                    store.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
                    return
                }

                let section = renderedSections[sectionIndex]
                let isCreatorMode = renderedSections.contains(where: { $0.creatorName != nil })

                if isCreatorMode {
                    let creatorSectionId = currentVisibleCreatorSectionId(in: visibleBounds, topicId: section.topicId)
                    store.updateViewportContext(topicId: section.topicId, subtopicId: nil, creatorSectionId: creatorSectionId)
                } else {
                    store.updateViewportContext(topicId: section.topicId, subtopicId: nil, creatorSectionId: nil)
                }
                return
            }

            guard store.pageDisplayMode == .saved else {
                store.updateVisibleWatchTopics([])
                store.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
                return
            }

            let visibleBounds = scrollView.contentView.bounds
            guard let sectionIndex = primaryVisibleSectionIndex(in: visibleBounds) else {
                store.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
                return
            }

            let section = renderedSections[sectionIndex]
            let isCreatorMode = renderedSections.contains(where: { $0.creatorName != nil })

            if isCreatorMode {
                let creatorSectionId = currentVisibleCreatorSectionId(in: visibleBounds, topicId: section.topicId)
                store.updateViewportContext(topicId: section.topicId, subtopicId: nil, creatorSectionId: creatorSectionId)
                return
            }

            let subtopicId = currentVisibleSubtopicId(inSectionAt: sectionIndex, visibleBounds: visibleBounds)
            store.updateViewportContext(topicId: section.topicId, subtopicId: subtopicId, creatorSectionId: nil)

            let duration = startedAt.duration(to: .now)
            let millis = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
            if millis >= 8 {
                AppLogger.discovery.debug(
                    "refreshViewportContext mode=\(store.pageDisplayMode.rawValue, privacy: .public) watchMode=\(store.watchPresentationMode.rawValue, privacy: .public) took \(Int(millis), privacy: .public)ms"
                )
            }
        }

        private func scheduleScrollFeedbackUpdate() {
            guard !scrollFeedbackUpdateScheduled else { return }
            scrollFeedbackUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollFeedbackUpdateScheduled = false
                self.refreshTopicScrollProgress()
                self.refreshViewportContext()
            }
        }

        private func primaryVisibleSectionIndex(in visibleBounds: CGRect) -> Int? {
            var bestIndex: Int?
            var bestPriority = Int.max
            var bestDistance = CGFloat.greatestFiniteMagnitude

            for sectionIndex in renderedSections.indices {
                guard let frame = frameForSection(at: sectionIndex) else { continue }

                let priority: Int
                let distance: CGFloat
                if frame.minY <= visibleBounds.minY, frame.maxY >= visibleBounds.minY {
                    priority = 0
                    distance = visibleBounds.minY - frame.minY
                } else if frame.minY > visibleBounds.minY {
                    priority = 1
                    distance = frame.minY - visibleBounds.minY
                } else {
                    priority = 2
                    distance = visibleBounds.minY - frame.maxY
                }

                if priority < bestPriority || (priority == bestPriority && distance < bestDistance) {
                    bestPriority = priority
                    bestDistance = distance
                    bestIndex = sectionIndex
                }
            }

            return bestIndex
        }

        private func visibleTopicIds(in visibleBounds: CGRect) -> [Int64] {
            var orderedTopicIds: [Int64] = []

            for sectionIndex in renderedSections.indices {
                guard let frame = frameForSection(at: sectionIndex),
                      frame.maxY >= visibleBounds.minY,
                      frame.minY <= visibleBounds.maxY else {
                    continue
                }

                let topicId = renderedSections[sectionIndex].topicId
                if !orderedTopicIds.contains(topicId) {
                    orderedTopicIds.append(topicId)
                }
            }

            return orderedTopicIds
        }

        private func currentVisibleCreatorSectionId(in visibleBounds: CGRect, topicId: Int64) -> String? {
            guard let collectionView else { return nil }

            let candidateIndices = renderedSections.indices.filter { renderedSections[$0].topicId == topicId && renderedSections[$0].creatorName != nil }
            guard !candidateIndices.isEmpty else { return nil }

            let dockTolerance: CGFloat = 1
            let dockedIndices = candidateIndices.filter { sectionIndex in
                let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
                guard let headerFrame = collectionView.collectionViewLayout?.layoutAttributesForSupplementaryView(
                    ofKind: NSCollectionView.elementKindSectionHeader,
                    at: headerIndexPath
                )?.frame else {
                    return false
                }
                return headerFrame.minY <= visibleBounds.minY + dockTolerance
            }

            if let docked = dockedIndices.max() {
                return renderedSections[docked].id
            }

            if let store,
               store.viewportTopicId == topicId,
               let current = store.viewportCreatorSectionId,
               candidateIndices.contains(where: { renderedSections[$0].id == current }) {
                return current
            }

            return candidateIndices.first.map { renderedSections[$0].id }
        }

        private func currentVisibleSubtopicId(inSectionAt sectionIndex: Int, visibleBounds: CGRect) -> Int64? {
            guard let collectionView,
                  renderedSections.indices.contains(sectionIndex) else { return nil }

            let section = renderedSections[sectionIndex]
            let visibleItems = collectionView.indexPathsForVisibleItems()
                .filter { $0.section == sectionIndex }
                .compactMap { indexPath -> (CGRect, VideoGridItemModel)? in
                    guard indexPath.item < section.videos.count,
                          let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return nil }
                    return (frame, section.videos[indexPath.item])
                }
                .sorted { lhs, rhs in
                    let lhsDistance = distanceFromViewportTop(lhs.0, visibleTop: visibleBounds.minY)
                    let rhsDistance = distanceFromViewportTop(rhs.0, visibleTop: visibleBounds.minY)
                    if lhsDistance == rhsDistance {
                        if lhs.0.minY == rhs.0.minY {
                            return lhs.0.minX < rhs.0.minX
                        }
                        return lhs.0.minY < rhs.0.minY
                    }
                    return lhsDistance < rhsDistance
                }

            for (_, video) in visibleItems {
                if let subtopicId = section.videoSubtopicMap[video.id] {
                    return subtopicId
                }
            }

            return nil
        }

        private func distanceFromViewportTop(_ frame: CGRect, visibleTop: CGFloat) -> CGFloat {
            if frame.minY <= visibleTop, frame.maxY >= visibleTop {
                return visibleTop - frame.minY
            }
            if frame.minY > visibleTop {
                return frame.minY - visibleTop
            }
            return visibleTop - frame.maxY
        }

        private func openOnYouTube(_ video: VideoGridItemModel) {
            store?.recordOpenedVideo(video)
            guard let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") else { return }
            NSWorkspace.shared.open(url)
        }

        private func handleMarqueeSelection(in rect: NSRect, modifiers: NSEvent.ModifierFlags, finalize: Bool) {
            guard let collectionView else { return }
            var base = Set<IndexPath>()
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                base = collectionView.selectionIndexPaths
            }
            let hits = Set(
                collectionView.indexPathsForVisibleItems().filter { indexPath in
                    guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return false }
                    return attributes.frame.intersects(rect)
                }
            )
            let merged = base.union(hits)
            isApplyingSelectionToCollectionView = true
            collectionView.deselectAll(nil)
            collectionView.selectItems(at: merged, scrollPosition: [])
            isApplyingSelectionToCollectionView = false
            if finalize {
                syncSelectionFromCollectionView()
            } else {
                refreshVisibleItems()
            }
        }

        private func menuForInteraction(at point: NSPoint) -> NSMenu? {
            guard let collectionView else { return nil }
            if let hitIndexPath = collectionView.indexPathForItem(at: point),
               let hitVideo = video(at: hitIndexPath),
               !renderedSelectedVideoIds.contains(hitVideo.id) {
                pendingSelectedVideoId = hitVideo.id
                pendingSelectedVideoIds = [hitVideo.id]
                renderedSelectedVideoId = hitVideo.id
                renderedSelectedVideoIds = [hitVideo.id]
                applySelectionToCollectionView()
                onSelectionChange(hitVideo.id, [hitVideo.id])
            }

            let selectedItems = renderedSelectedVideoIds.compactMap(videoById)
            guard !selectedItems.isEmpty else { return nil }

            let menu = NSMenu()
            let selectionCount = selectedItems.count
            let allCandidates = selectedItems.allSatisfy { isCandidateVideo($0.id) }
            let allSaved = selectedItems.allSatisfy { !isCandidateVideo($0.id) }
            let selectedVideoIds = selectedItems.map(\.id)
            let selectedCreatorKeys = Set(selectedItems.compactMap { video -> String? in
                guard let channelId = video.channelId, !channelId.isEmpty else { return nil }
                return channelId
            })
            let singleSelectedCreator = selectedCreatorKeys.count == 1
                ? selectedItems.first(where: { $0.channelId == selectedCreatorKeys.first })
                : nil

            let openTitle = selectionCount == 1 ? "Open on YouTube" : "Open \(selectionCount) on YouTube"
            let openItem = NSMenuItem(title: openTitle, action: #selector(contextOpenOnYouTube(_:)), keyEquivalent: "\r")
            openItem.target = self
            menu.addItem(openItem)
            let copyTitle = selectionCount == 1 ? "Copy Link" : "Copy \(selectionCount) Links"
            let copyItem = NSMenuItem(title: copyTitle, action: #selector(contextCopyLinks(_:)), keyEquivalent: "c")
            copyItem.keyEquivalentModifierMask = [.command]
            copyItem.target = self
            menu.addItem(copyItem)

            if let store {
                menu.addItem(.separator())
                let saveToWatchLater = NSMenuItem(title: "Save to Watch Later", action: #selector(contextSaveToWatchLater(_:)), keyEquivalent: "")
                saveToWatchLater.target = self
                saveToWatchLater.keyEquivalent = "l"
                let watchLaterMembershipCount = selectedVideoIds.reduce(into: 0) { count, videoId in
                    if store.playlistsForVideo(videoId).contains(where: { $0.playlistId == "WL" }) {
                        count += 1
                    }
                }
                if watchLaterMembershipCount == selectionCount {
                    saveToWatchLater.state = .on
                    saveToWatchLater.isEnabled = false
                } else if watchLaterMembershipCount > 0 {
                    saveToWatchLater.state = .mixed
                    saveToWatchLater.isEnabled = true
                } else {
                    saveToWatchLater.state = .off
                    saveToWatchLater.isEnabled = true
                }
                menu.addItem(saveToWatchLater)

                let playlistsMenu = buildSaveToPlaylistMenu(selectedVideoIds: selectedVideoIds, selectionCount: selectionCount)
                let saveToPlaylist = NSMenuItem(title: "Save to Playlist", action: nil, keyEquivalent: "")
                saveToPlaylist.submenu = playlistsMenu
                saveToPlaylist.keyEquivalent = "p"
                menu.addItem(saveToPlaylist)

                if allSaved {
                    if let moveMenu = buildMoveToPlaylistMenu(selectedVideoIds: selectedVideoIds),
                       !moveMenu.items.isEmpty {
                        let moveItem = NSMenuItem(title: "Move to Playlist", action: nil, keyEquivalent: "")
                        moveItem.submenu = moveMenu
                        moveItem.keyEquivalent = "p"
                        moveItem.keyEquivalentModifierMask = [.shift]
                        menu.addItem(moveItem)
                    }

                    let removablePlaylists = removablePlaylists(for: selectedVideoIds)
                    switch removablePlaylists.count {
                    case 0:
                        break
                    case 1:
                        let playlist = removablePlaylists[0]
                        let removeItem = NSMenuItem(
                            title: "Remove from \(playlist.title)",
                            action: #selector(contextRemoveFromPlaylist(_:)),
                            keyEquivalent: ""
                        )
                        removeItem.representedObject = playlist
                        removeItem.target = self
                        menu.addItem(removeItem)
                    default:
                        let removeMenu = NSMenu(title: "Remove from Playlist")
                        for playlist in removablePlaylists {
                            let item = NSMenuItem(title: playlist.title, action: #selector(contextRemoveFromPlaylist(_:)), keyEquivalent: "")
                            item.representedObject = playlist
                            item.target = self
                            let membershipCount = selectedVideoIds.reduce(into: 0) { count, videoId in
                                if store.playlistsForVideo(videoId).contains(where: { $0.playlistId == playlist.playlistId }) {
                                    count += 1
                                }
                            }
                            if membershipCount == selectionCount {
                                item.state = .on
                            } else if membershipCount > 0 {
                                item.state = .mixed
                            } else {
                                item.state = .off
                            }
                            removeMenu.addItem(item)
                        }
                        let removeItem = NSMenuItem(title: "Remove from Playlist", action: nil, keyEquivalent: "")
                        removeItem.submenu = removeMenu
                        removeItem.isEnabled = !removeMenu.items.isEmpty
                        menu.addItem(removeItem)
                    }

                }

                if allCandidates, store.selectedTopicId != nil {
                    menu.addItem(.separator())
                    let dismiss = NSMenuItem(title: "Dismiss", action: #selector(contextDismissCandidates(_:)), keyEquivalent: "")
                    dismiss.target = self
                    dismiss.keyEquivalent = "d"
                    menu.addItem(dismiss)

                    let notInterested = NSMenuItem(title: "Not Interested", action: #selector(contextNotInterested(_:)), keyEquivalent: "")
                    notInterested.target = self
                    notInterested.keyEquivalent = "n"
                    menu.addItem(notInterested)

                    if let creator = singleSelectedCreator,
                       let channelId = creator.channelId,
                       !channelId.isEmpty {
                        let excludeCreator = NSMenuItem(title: "Exclude Creator from Watch", action: #selector(contextExcludeCreatorFromWatch(_:)), keyEquivalent: "")
                        excludeCreator.representedObject = [
                            "channelId": channelId,
                            "channelName": creator.channelName ?? "",
                            "channelIconUrl": creator.channelIconUrl?.absoluteString ?? ""
                        ]
                        excludeCreator.target = self
                        menu.addItem(excludeCreator)
                    }
                }

                for item in menu.items {
                    item.target = self
                }

                menu.autoenablesItems = false
                saveToPlaylist.isEnabled = !store.knownPlaylists().isEmpty
            } else {
                for item in menu.items {
                    item.target = self
                }
            }

            return menu
        }

        private func indexPaths(for ids: Set<String>) -> [IndexPath] {
            renderedSections.enumerated().flatMap { sectionIndex, section in
                section.videos.enumerated().compactMap { itemIndex, video in
                    ids.contains(video.id) ? IndexPath(item: itemIndex, section: sectionIndex) : nil
                }
            }
        }

        private func video(at indexPath: IndexPath) -> VideoGridItemModel? {
            guard indexPath.section < renderedSections.count,
                  indexPath.item < renderedSections[indexPath.section].videos.count else { return nil }
            return renderedSections[indexPath.section].videos[indexPath.item]
        }

        private func videoById(_ id: String) -> VideoGridItemModel? {
            renderedSections.lazy.flatMap(\.videos).first(where: { $0.id == id })
        }

        private func isCandidateVideo(_ videoId: String) -> Bool {
            renderedSections.contains { section in
                section.displayMode == .watchCandidates && section.videos.contains(where: { $0.id == videoId })
            }
        }

        @objc private func contextOpenOnYouTube(_ sender: Any?) {
            for item in renderedSelectedVideoIds.compactMap(videoById) {
                openOnYouTube(item)
            }
        }

        @objc private func contextCopyLinks(_ sender: Any?) {
            let links = renderedSelectedVideoIds.map { "https://www.youtube.com/watch?v=\($0)" }.sorted()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        }

        @objc private func contextDismissCandidates(_ sender: Any?) {
            guard let store, let topicId = store.selectedTopicId else { return }
            store.dismissCandidates(topicId: topicId, videoIds: Array(renderedSelectedVideoIds))
        }

        @objc private func contextSaveToWatchLater(_ sender: Any?) {
            guard let store else { return }
            if let topicId = store.selectedTopicId,
               renderedSelectedVideoIds.allSatisfy(isCandidateVideo) {
                store.saveCandidatesToWatchLater(topicId: topicId, videoIds: Array(renderedSelectedVideoIds))
            } else {
                store.saveVideosToWatchLater(videoIds: Array(renderedSelectedVideoIds))
            }
        }

        @objc private func contextExcludeCreatorFromWatch(_ sender: Any?) {
            guard let store,
                  let payload = (sender as? NSMenuItem)?.representedObject as? [String: String],
                  let channelId = payload["channelId"], !channelId.isEmpty else {
                return
            }

            let channelName = payload["channelName"]
            let channelIconUrl = payload["channelIconUrl"]
            store.excludeCreatorFromWatch(
                channelId: channelId,
                channelName: channelName,
                channelIconUrl: channelIconUrl?.isEmpty == false ? channelIconUrl : nil
            )
        }

        private func handleSaveToWatchLaterShortcut() {
            guard !renderedSelectedVideoIds.isEmpty else { return }
            contextSaveToWatchLater(nil)
        }

        private func handleSaveToPlaylistShortcut() {
            guard !renderedSelectedVideoIds.isEmpty else { return }
            showPlaylistPopup(mode: .save)
        }

        private func handleMoveToPlaylistShortcut() {
            guard !renderedSelectedVideoIds.isEmpty else { return }
            showPlaylistPopup(mode: .move)
        }

        private func handleDismissShortcut() {
            guard let store, store.selectedTopicId != nil,
                  !renderedSelectedVideoIds.isEmpty,
                  renderedSelectedVideoIds.allSatisfy(isCandidateVideo) else { return }
            contextDismissCandidates(nil)
        }

        private func handleNotInterestedShortcut() {
            guard let store, store.selectedTopicId != nil,
                  !renderedSelectedVideoIds.isEmpty,
                  renderedSelectedVideoIds.allSatisfy(isCandidateVideo) else { return }
            contextNotInterested(nil)
        }

        private func handleOpenSelectedShortcut() {
            guard !renderedSelectedVideoIds.isEmpty else { return }
            contextOpenOnYouTube(nil)
        }

        private func handleClearSelectionShortcut() {
            guard let collectionView else { return }
            pendingSelectedVideoId = nil
            pendingSelectedVideoIds = []
            renderedSelectedVideoId = nil
            renderedSelectedVideoIds = []
            isApplyingSelectionToCollectionView = true
            collectionView.deselectAll(nil)
            isApplyingSelectionToCollectionView = false
            onSelectionChange(nil, [])
            refreshVisibleItems()
        }

        @objc private func contextSaveToPlaylist(_ sender: NSMenuItem) {
            guard let store,
                  let playlist = sender.representedObject as? PlaylistRecord else { return }
            if let topicId = store.selectedTopicId,
               renderedSelectedVideoIds.allSatisfy(isCandidateVideo) {
                store.saveCandidatesToPlaylist(topicId: topicId, videoIds: Array(renderedSelectedVideoIds), playlist: playlist)
            } else {
                store.saveVideosToPlaylist(videoIds: Array(renderedSelectedVideoIds), playlist: playlist)
            }
        }

        @objc private func contextMoveToPlaylist(_ sender: NSMenuItem) {
            guard let store,
                  let destination = sender.representedObject as? PlaylistRecord,
                  let sourcePlaylistId = store.selectedPlaylistId,
                  sourcePlaylistId != destination.playlistId,
                  let sourcePlaylist = store.knownPlaylists().first(where: { $0.playlistId == sourcePlaylistId }) else { return }

            store.saveVideosToPlaylist(videoIds: Array(renderedSelectedVideoIds), playlist: destination)
            store.removeVideosFromPlaylist(videoIds: Array(renderedSelectedVideoIds), playlist: sourcePlaylist)
        }

        @objc private func contextRemoveFromPlaylist(_ sender: NSMenuItem) {
            guard let store,
                  let playlist = sender.representedObject as? PlaylistRecord else { return }
            store.removeVideosFromPlaylist(videoIds: Array(renderedSelectedVideoIds), playlist: playlist)
        }

        @objc private func contextNotInterested(_ sender: Any?) {
            guard let store, let topicId = store.selectedTopicId else { return }
            store.markCandidatesNotInterested(topicId: topicId, videoIds: Array(renderedSelectedVideoIds))
        }

        private enum PlaylistShortcutMode {
            case save
            case move
        }

        private func showPlaylistPopup(mode: PlaylistShortcutMode) {
            guard let collectionView else { return }
            let selectedVideoIds = renderedSelectedVideoIds.map { $0 }
            let selectionCount = selectedVideoIds.count
            let menu: NSMenu?
            switch mode {
            case .save:
                menu = buildSaveToPlaylistMenu(selectedVideoIds: selectedVideoIds, selectionCount: selectionCount)
            case .move:
                menu = buildMoveToPlaylistMenu(selectedVideoIds: selectedVideoIds)
            }

            guard let menu, !menu.items.isEmpty else {
                NSSound.beep()
                return
            }

            let popupPoint: NSPoint
            if let indexPath = indexPaths(for: renderedSelectedVideoIds).sorted().first,
               let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
                popupPoint = NSPoint(x: attributes.frame.midX, y: attributes.frame.midY)
            } else {
                popupPoint = NSPoint(x: collectionView.visibleRect.midX, y: collectionView.visibleRect.midY)
            }

            menu.popUp(positioning: nil, at: popupPoint, in: collectionView)
        }

        private func buildSaveToPlaylistMenu(selectedVideoIds: [String], selectionCount: Int) -> NSMenu {
            let playlistsMenu = NSMenu(title: "Save to Playlist")
            guard let store else { return playlistsMenu }

            for (index, playlist) in store.knownPlaylists().enumerated() {
                let item = NSMenuItem(title: playlist.title, action: #selector(contextSaveToPlaylist(_:)), keyEquivalent: "")
                if index < 9 {
                    item.title = "\(index + 1). \(playlist.title)"
                }
                item.representedObject = playlist
                item.target = self
                let membershipCount = selectedVideoIds.reduce(into: 0) { count, videoId in
                    if store.playlistsForVideo(videoId).contains(where: { $0.playlistId == playlist.playlistId }) {
                        count += 1
                    }
                }
                if membershipCount == selectionCount {
                    item.state = .on
                    item.isEnabled = false
                } else if membershipCount > 0 {
                    item.state = .mixed
                    item.isEnabled = true
                } else {
                    item.state = .off
                    item.isEnabled = true
                }
                playlistsMenu.addItem(item)
            }
            return playlistsMenu
        }

        private func buildMoveToPlaylistMenu(selectedVideoIds: [String]) -> NSMenu? {
            guard let store,
                  !selectedVideoIds.isEmpty,
                  let sourcePlaylistId = store.selectedPlaylistId else { return nil }

            let menu = NSMenu(title: "Move to Playlist")
            for playlist in store.knownPlaylists().filter({ $0.playlistId != sourcePlaylistId }) {
                let item = NSMenuItem(title: playlist.title, action: #selector(contextMoveToPlaylist(_:)), keyEquivalent: "")
                item.representedObject = playlist
                item.target = self
                menu.addItem(item)
            }
            return menu
        }

        private func removablePlaylists(for selectedVideoIds: [String]) -> [PlaylistRecord] {
            guard let store else { return [] }
            let removablePlaylistIds = Set(
                selectedVideoIds.flatMap { store.playlistsForVideo($0).map(\.playlistId) }
            )
            return store.knownPlaylists().filter { removablePlaylistIds.contains($0.playlistId) }
        }

        private func installActionObserversIfNeeded() {
            guard actionObservers.isEmpty else { return }
            let center = NotificationCenter.default
            actionObservers = [
                center.addObserver(forName: AppCommandBridge.saveToWatchLater, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleSaveToWatchLaterShortcut() }
                },
                center.addObserver(forName: AppCommandBridge.saveToPlaylist, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleSaveToPlaylistShortcut() }
                },
                center.addObserver(forName: AppCommandBridge.moveToPlaylist, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleMoveToPlaylistShortcut() }
                },
                center.addObserver(forName: AppCommandBridge.dismissCandidates, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleDismissShortcut() }
                },
                center.addObserver(forName: AppCommandBridge.notInterested, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleNotInterestedShortcut() }
                },
                center.addObserver(forName: AppCommandBridge.openOnYouTube, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleOpenSelectedShortcut() }
                },
                center.addObserver(forName: AppCommandBridge.clearSelection, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleClearSelectionShortcut() }
                }
            ]
        }
    }
}
