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
            },
            showToast: { message, icon in
                displaySettings.toast.show(message, icon: icon)
            }
        )
        .task {
            loadAndFilter()
            if store.selectedVideoId == nil,
               let first = sections.lazy.flatMap(\.videos).first(where: { !$0.isPlaceholder }) {
                store.selectedVideoId = first.id
            }
            // Auto-focus the grid on launch so keyboard shortcuts work
            // immediately without requiring a click first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                displaySettings.focusGridRequested = true
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
            loadAndFilter()
        }
        .onChange(of: store.watchPoolVersion) { _, _ in loadAndFilter() }
    }

    private func loadAndFilter() {
        let startedAt = ContinuousClock.now
        let result = CollectionGridSectionFactory.buildSections(
            store: store,
            displaySettings: displaySettings
        )
        let afterBuild = ContinuousClock.now

        let sectionsChanged = result.sections != sections
        let afterCompare = ContinuousClock.now
        let searchCountChanged = result.searchResultCount != store.searchResultCount

        if searchCountChanged {
            store.searchResultCount = result.searchResultCount
        }

        // Publish per-topic match counts so the sidebar can filter to topics
        // with hits and show matching counts instead of raw totals.
        if store.parsedQuery.isEmpty {
            if !store.searchMatchesByTopic.isEmpty {
                store.searchMatchesByTopic = [:]
            }
        } else {
            var counts: [Int64: Int] = [:]
            for section in result.sections where section.topicId > 0 {
                counts[section.topicId, default: 0] += section.videos.count
            }
            if counts != store.searchMatchesByTopic {
                store.searchMatchesByTopic = counts
            }
        }

        if sectionsChanged {
            sections = result.sections
            sectionGeneration += 1
        }
        let totalVideos = result.sections.reduce(0) { $0 + $1.videos.count }
        AppLogger.file.log(
            "⏱ loadAndFilter build=\((startedAt.duration(to: afterBuild)).formatted(.units(allowed: [.milliseconds], width: .narrow))) compare=\((afterBuild.duration(to: afterCompare)).formatted(.units(allowed: [.milliseconds], width: .narrow))) total=\((startedAt.duration(to: .now)).formatted(.units(allowed: [.milliseconds], width: .narrow))) sections=\(result.sections.count) videos=\(totalVideos) changed=\(sectionsChanged)",
            category: "perf"
        )
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
    var showToast: (String, String) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelect: onSelect,
            onSelectionChange: onSelectionChange,
            onClearTopicScrollRequest: onClearTopicScrollRequest,
            onClearSectionScrollRequest: onClearSectionScrollRequest,
            onClearGridFocusRequest: onClearGridFocusRequest,
            showToast: showToast
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

    static func dismantleNSView(_ nsView: CollectionGridContainerView, coordinator: Coordinator) {
        coordinator.teardown()
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
        private let commandObservers = CollectionGridCommandObservers()
        private var scrollFeedbackUpdateScheduled = false

        var cacheDir: URL = URL(fileURLWithPath: "/tmp")
        var thumbnailSize: Double = 220
        var showMetadata: Bool = true
        var onSelect: (String) -> Void
        var onSelectionChange: (String?, Set<String>) -> Void
        var onClearTopicScrollRequest: () -> Void
        var onClearSectionScrollRequest: () -> Void
        var onClearGridFocusRequest: () -> Void
        var showToast: (String, String) -> Void  // (message, sfSymbol)

        init(
            onSelect: @escaping (String) -> Void,
            onSelectionChange: @escaping (String?, Set<String>) -> Void,
            onClearTopicScrollRequest: @escaping () -> Void,
            onClearSectionScrollRequest: @escaping () -> Void,
            onClearGridFocusRequest: @escaping () -> Void,
            showToast: @escaping (String, String) -> Void = { _, _ in }
        ) {
            self.onSelect = onSelect
            self.onSelectionChange = onSelectionChange
            self.onClearTopicScrollRequest = onClearTopicScrollRequest
            self.onClearSectionScrollRequest = onClearSectionScrollRequest
            self.onClearGridFocusRequest = onClearGridFocusRequest
            self.showToast = showToast
        }

        func attach(to container: CollectionGridContainerView) {
            guard self.container !== container else { return }
            detachFromContainer()
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
            container.collectionView.onNotForMeShortcut = { [weak self] in
                self?.handleNotForMeShortcut()
            }
            container.collectionView.onOpenSelectedShortcut = { [weak self] in
                self?.handleOpenSelectedShortcut()
            }
            container.collectionView.onClearSelectionShortcut = { [weak self] in
                self?.handleClearSelectionShortcut()
            }
            container.collectionView.onToggleShowDismissedShortcut = { [weak self] in
                self?.handleToggleShowDismissedShortcut()
            }
            container.onReadyForFlush = { [weak self] in
                self?.flushIfReady()
            }
            container.onBoundsChanged = { [weak self] in
                self?.scheduleScrollFeedbackUpdate()
            }
            installActionObserversIfNeeded()
        }

        func teardown() {
            commandObservers.removeAll()
            detachFromContainer()
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
                AppLogger.file.log("⏱ applySnapshot: new generation=\(generation) sections=\(sections.count) videos=\(sections.reduce(0) { $0 + $1.videos.count })", category: "perf")
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
            let afterReload = ContinuousClock.now

            let shouldInvalidateLayout = needsLayoutInvalidation || widthChanged
            if shouldInvalidateLayout {
                needsLayoutInvalidation = false
                renderedContentWidth = currentContentWidth
                container.flowLayout.invalidateLayout()
            }

            // Skip forced synchronous layout — it takes ~950ms with 400
            // items because every NSHostingView<VideoCellContent> must
            // evaluate its SwiftUI body. Let AppKit schedule layout
            // naturally in the next display cycle instead.
            let afterLayout = ContinuousClock.now

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

            if shouldReload || shouldInvalidateLayout {
                AppLogger.file.log("⏱ flushIfReady reload=\(shouldReload) reloadData=\((startedAt.duration(to: afterReload)).formatted(.units(allowed: [.milliseconds], width: .narrow))) layout=\((afterReload.duration(to: afterLayout)).formatted(.units(allowed: [.milliseconds], width: .narrow))) total=\((startedAt.duration(to: .now)).formatted(.units(allowed: [.milliseconds], width: .narrow))) items=\(self.renderedSections.reduce(0) { $0 + $1.videos.count })", category: "perf")
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
            headerModelBuilder.headerHeight(for: section)
        }

        private func headerModel(for section: TopicSection, at sectionIndex: Int?) -> CollectionSectionHeaderModel {
            headerModelBuilder.headerModel(for: section, at: sectionIndex)
        }

        private var headerModelBuilder: CollectionGridHeaderModelBuilder {
            CollectionGridHeaderModelBuilder(
                store: store,
                renderedSections: renderedSections,
                topicScrollProgress: { [weak self] topicId in
                    self?.topicScrollProgress(forTopicId: topicId) ?? 0
                },
                sectionScrollProgress: { [weak self] sectionIndex in
                    self?.sectionScrollProgress(forSectionAt: sectionIndex) ?? 0
                }
            )
        }

        private func topicScrollProgress(forTopicId topicId: Int64) -> Double {
            CollectionGridViewportSupport.topicScrollProgress(
                collectionView: collectionView,
                renderedSections: renderedSections,
                topicId: topicId,
                frameForSection: { [weak self] in self?.frameForSection(at: $0) }
            )
        }

        private func sectionScrollProgress(forSectionAt sectionIndex: Int) -> Double {
            CollectionGridViewportSupport.sectionScrollProgress(
                collectionView: collectionView,
                renderedSections: renderedSections,
                sectionIndex: sectionIndex,
                frameForSection: { [weak self] in self?.frameForSection(at: $0) }
            )
        }

        private func frameForSection(at sectionIndex: Int) -> CGRect? {
            CollectionGridViewportSupport.frameForSection(
                collectionView: collectionView,
                sectionIndex: sectionIndex
            )
        }

        private func refreshVisibleHeaders() {
            CollectionGridViewportSupport.refreshVisibleHeaders(
                collectionView: collectionView,
                renderedSections: renderedSections,
                headerModel: { [weak self] sectionIndex in
                    guard let self else {
                        return .topic(
                            name: "",
                            count: 0,
                            totalCount: nil,
                            topicId: 0,
                            scrollProgress: 0,
                            highlightTerms: [],
                            displayMode: .saved,
                            channels: [],
                            selectedChannelId: nil,
                            videoCountForChannel: { _ in 0 },
                            hasRecentContent: { _ in false },
                            latestPublishedAtForChannel: { _ in nil },
                            themeLabelsForChannel: { _ in [] },
                            subscriberCountForChannel: { _ in nil },
                            onSelectChannel: { _ in },
                            onOpenCreatorDetail: { _ in }
                        )
                    }
                    return self.headerModel(for: self.renderedSections[sectionIndex], at: sectionIndex)
                }
            )
        }

        private func refreshTopicScrollProgress() {
            CollectionGridViewportSupport.refreshTopicScrollProgress(
                store: store,
                topicScrollProgress: { [weak self] in self?.topicScrollProgress(forTopicId: $0) ?? 0 }
            )
        }

        private func refreshViewportContext() {
            CollectionGridViewportSupport.refreshViewportContext(
                store: store,
                collectionView: collectionView,
                renderedSections: renderedSections,
                visibleTopicIds: { [weak self] in self?.visibleTopicIds(in: $0) ?? [] },
                primaryVisibleSectionIndex: { [weak self] in self?.primaryVisibleSectionIndex(in: $0) },
                currentVisibleCreatorSectionId: { [weak self] in self?.currentVisibleCreatorSectionId(in: $0, topicId: $1) },
                currentVisibleSubtopicId: { [weak self] in self?.currentVisibleSubtopicId(inSectionAt: $0, visibleBounds: $1) }
            )
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
            CollectionGridViewportSupport.primaryVisibleSectionIndex(
                renderedSections: renderedSections,
                visibleBounds: visibleBounds,
                frameForSection: { [weak self] in self?.frameForSection(at: $0) }
            )
        }

        private func visibleTopicIds(in visibleBounds: CGRect) -> [Int64] {
            CollectionGridViewportSupport.visibleTopicIds(
                renderedSections: renderedSections,
                visibleBounds: visibleBounds,
                frameForSection: { [weak self] in self?.frameForSection(at: $0) }
            )
        }

        private func currentVisibleCreatorSectionId(in visibleBounds: CGRect, topicId: Int64) -> String? {
            CollectionGridViewportSupport.currentVisibleCreatorSectionId(
                collectionView: collectionView,
                renderedSections: renderedSections,
                visibleBounds: visibleBounds,
                topicId: topicId,
                viewportTopicId: store?.viewportTopicId,
                viewportCreatorSectionId: store?.viewportCreatorSectionId
            )
        }

        private func currentVisibleSubtopicId(inSectionAt sectionIndex: Int, visibleBounds: CGRect) -> Int64? {
            CollectionGridViewportSupport.currentVisibleSubtopicId(
                collectionView: collectionView,
                renderedSections: renderedSections,
                sectionIndex: sectionIndex,
                visibleBounds: visibleBounds
            )
        }

        private func distanceFromViewportTop(_ frame: CGRect, visibleTop: CGFloat) -> CGFloat {
            CollectionGridViewportSupport.distanceFromViewportTop(frame, visibleTop: visibleTop)
        }

        private func openOnYouTube(_ video: VideoGridItemModel) {
            store?.recordOpenedVideo(video)
            // Implicit like: opening a video = positive signal for ranking
            store?.recordLike(
                videoId: video.id,
                channelId: video.channelId,
                duration: video.duration,
                topicId: video.topicId
            )
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
            let allCandidates = selectedItems.allSatisfy { isCandidateVideo($0.id) }
            let allSaved = selectedItems.allSatisfy { !isCandidateVideo($0.id) }
            return CollectionGridContextMenuBuilder.build(
                store: store,
                selectedItems: selectedItems,
                allCandidates: allCandidates,
                allSaved: allSaved,
                target: self,
                openAction: #selector(contextOpenOnYouTube(_:)),
                copyAction: #selector(contextCopyLinks(_:)),
                saveToWatchLaterAction: #selector(contextSaveToWatchLater(_:)),
                saveToPlaylistAction: #selector(contextSaveToPlaylist(_:)),
                moveToPlaylistAction: #selector(contextMoveToPlaylist(_:)),
                removeFromPlaylistAction: #selector(contextRemoveFromPlaylist(_:)),
                downloadVideoAction: #selector(contextDownloadVideo(_:)),
                cancelDownloadAction: #selector(contextCancelDownload(_:)),
                playOfflineAction: #selector(contextPlayOffline(_:)),
                deleteDownloadAction: #selector(contextDeleteDownload(_:)),
                dismissCandidatesAction: #selector(contextDismissCandidates(_:)),
                notInterestedAction: #selector(contextNotInterested(_:)),
                excludeCreatorAction: #selector(contextExcludeCreatorFromWatch(_:))
            )
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
            CollectionGridActionSupport.excludeCreatorFromWatch(store: store, sender: sender)
        }

        private func handleSaveToWatchLaterShortcut() {
            let t0 = ContinuousClock.now
            guard let store else { return }
            let videoIds = Array(renderedSelectedVideoIds)
            guard !videoIds.isEmpty else { return }
            // Same direct pattern as dismiss — skip the gate, go straight
            // to the store. The local membership + badge appear instantly;
            // the YouTube API sync runs in the background.
            if let topicId = store.selectedTopicId,
               videoIds.allSatisfy(isCandidateVideo) {
                store.saveCandidatesToWatchLater(topicId: topicId, videoIds: videoIds)
            } else {
                store.saveVideosToWatchLater(videoIds: videoIds)
            }
            showToast("Saved to Watch Later", "clock")
            AppLogger.file.log("⏱ handleWatchLater: total=\((t0.duration(to: .now)).formatted(.units(allowed: [.milliseconds], width: .narrow)))", category: "perf")
        }

        private func handleSaveToPlaylistShortcut() {
            CollectionGridActionSupport.handleSaveToPlaylistShortcut(selectedVideoIds: renderedSelectedVideoIds) {
                showPlaylistPopup(mode: .save)
            }
        }

        private func handleMoveToPlaylistShortcut() {
            CollectionGridActionSupport.handleMoveToPlaylistShortcut(selectedVideoIds: renderedSelectedVideoIds) {
                showPlaylistPopup(mode: .move)
            }
        }

        private func handleDismissShortcut() {
            let t0 = ContinuousClock.now
            guard let store else {
                AppLogger.commands.info("Dismiss: no store")
                return
            }
            guard let topicId = store.selectedTopicId else {
                AppLogger.commands.info("Dismiss: no selectedTopicId")
                return
            }
            let videoIds = Array(renderedSelectedVideoIds)
            guard !videoIds.isEmpty else {
                AppLogger.commands.info("Dismiss: no selected videos")
                return
            }

            // If showing dismissed videos, 'd' on a dismissed video restores it
            if store.showDismissedCandidates {
                let dismissedVideoIds = videoIds.filter { id in
                    renderedSections.flatMap(\.videos).first(where: { $0.id == id })?.stateTag == "Dismissed"
                }
                if !dismissedVideoIds.isEmpty {
                    for videoId in dismissedVideoIds {
                        store.setCandidateState(topicId: topicId, videoId: videoId, state: .candidate)
                    }
                    showToast("Restored", "arrow.uturn.backward.circle")
                    return
                }
            }

            AppLogger.commands.info("Dismiss: \(videoIds.count) videos in topic \(topicId)")
            store.dismissCandidates(topicId: topicId, videoIds: videoIds)
            let t1 = ContinuousClock.now
            autoAdvanceSelection()
            let t2 = ContinuousClock.now
            showToast("Dismissed", "xmark.circle")
            AppLogger.file.log("⏱ handleDismiss: store=\((t0.duration(to: t1)).formatted(.units(allowed: [.milliseconds], width: .narrow))) autoAdvance=\((t1.duration(to: t2)).formatted(.units(allowed: [.milliseconds], width: .narrow))) total=\((t0.duration(to: .now)).formatted(.units(allowed: [.milliseconds], width: .narrow)))", category: "perf")
        }

        private func handleNotInterestedShortcut() {
            guard let store else {
                AppLogger.commands.info("NotInterested: no store")
                return
            }
            guard let topicId = store.selectedTopicId else {
                AppLogger.commands.info("NotInterested: no selectedTopicId")
                return
            }
            let videoIds = Array(renderedSelectedVideoIds)
            guard !videoIds.isEmpty else {
                AppLogger.commands.info("NotInterested: no selected videos")
                return
            }
            AppLogger.commands.info("NotInterested: \(videoIds.count) videos in topic \(topicId)")
            store.markCandidatesNotInterested(topicId: topicId, videoIds: videoIds)
            showToast("Not Interested", "hand.thumbsdown")
        }

        private func handleNotForMeShortcut() {
            guard let store else {
                AppLogger.commands.info("NotForMe: no store")
                return
            }
            guard let topicId = store.selectedTopicId else {
                AppLogger.commands.info("NotForMe: no selectedTopicId")
                return
            }
            let videoIds = Array(renderedSelectedVideoIds)
            guard !videoIds.isEmpty else {
                AppLogger.commands.info("NotForMe: no selected videos")
                return
            }
            AppLogger.commands.info("NotForMe: \(videoIds.count) videos in topic \(topicId)")
            for videoId in videoIds {
                let video = videoById(videoId)
                store.notForMe(
                    topicId: topicId,
                    videoId: videoId,
                    channelId: video?.channelId,
                    duration: video?.duration
                )
            }
            autoAdvanceSelection()
            showToast("Not for me", "xmark.circle.fill")
        }

        /// After dismissing a video, auto-select the card that fills the
        /// dismissed position so the user can keep hammering d without the
        /// selection jumping to the start of the grid.
        private func autoAdvanceSelection() {
            guard collectionView != nil else { return }
            let allVideos = renderedSections.flatMap(\.videos).filter { !$0.isPlaceholder }
            let dismissedIds = renderedSelectedVideoIds
            // Find where the first dismissed video sat in the list
            let dismissedIndex = allVideos.firstIndex { dismissedIds.contains($0.id) }
            let remaining = allVideos.filter { !dismissedIds.contains($0.id) }
            // Pick the video that fills the same position (or the last one if we dismissed the tail)
            let targetIndex = min(dismissedIndex ?? 0, remaining.count - 1)
            if targetIndex >= 0, targetIndex < remaining.count {
                let next = remaining[targetIndex]
                let nextId = next.id
                // Brief delay so the pool removal propagates before we select
                DispatchQueue.main.async { [weak self] in
                    self?.store?.selectedVideoId = nextId
                    self?.onSelect(nextId)
                    self?.renderedSelectedVideoIds = [nextId]
                    self?.renderedSelectedVideoId = nextId
                    self?.pendingSelectedVideoIds = [nextId]
                    self?.pendingSelectedVideoId = nextId
                    self?.onSelectionChange(nextId, [nextId])
                    self?.applySelectionToCollectionView()
                }
            }
        }

        private func handleOpenSelectedShortcut() {
            CollectionGridActionSupport.handleOpenSelectedShortcut(selectedVideoIds: renderedSelectedVideoIds) {
                contextOpenOnYouTube(nil)
            }
        }

        private func handleToggleShowDismissedShortcut() {
            guard let store else { return }
            store.toggleShowDismissedCandidates()
            let showing = store.showDismissedCandidates
            showToast(showing ? "Showing Dismissed" : "Hiding Dismissed", showing ? "eye" : "eye.slash")
        }

        private func handleClearSelectionShortcut() {
            CollectionGridActionSupport.clearSelection(
                collectionView: collectionView,
                selectedVideoIds: &pendingSelectedVideoIds,
                selectedVideoId: &pendingSelectedVideoId,
                renderedSelectedVideoIds: &renderedSelectedVideoIds,
                renderedSelectedVideoId: &renderedSelectedVideoId,
                isApplyingSelectionToCollectionView: &isApplyingSelectionToCollectionView,
                onSelectionChange: onSelectionChange,
                refreshVisibleItems: refreshVisibleItems
            )
        }

        @objc private func contextSaveToPlaylist(_ sender: NSMenuItem) {
            CollectionGridActionSupport.saveToPlaylist(
                store: store,
                sender: sender,
                selectedVideoIds: renderedSelectedVideoIds,
                allCandidatesEligible: renderedSelectedVideoIds.allSatisfy(isCandidateVideo)
            )
        }

        @objc private func contextMoveToPlaylist(_ sender: NSMenuItem) {
            CollectionGridActionSupport.moveToPlaylist(
                store: store,
                sender: sender,
                selectedVideoIds: renderedSelectedVideoIds
            )
        }

        @objc private func contextRemoveFromPlaylist(_ sender: NSMenuItem) {
            CollectionGridActionSupport.removeFromPlaylist(
                store: store,
                sender: sender,
                selectedVideoIds: renderedSelectedVideoIds
            )
        }

        @objc private func contextNotInterested(_ sender: Any?) {
            CollectionGridActionSupport.markNotInterested(
                store: store,
                selectedVideoIds: renderedSelectedVideoIds
            )
        }

        @objc private func contextDownloadVideo(_ sender: Any?) {
            CollectionGridActionSupport.withFirstSelectedVideo(selectedVideoIds: renderedSelectedVideoIds) {
                VideoDownloadManager.shared.download(videoId: $0)
            }
        }

        @objc private func contextPlayOffline(_ sender: Any?) {
            CollectionGridActionSupport.withFirstSelectedVideo(selectedVideoIds: renderedSelectedVideoIds) {
                VideoDownloadManager.shared.playOffline(videoId: $0)
            }
        }

        @objc private func contextCancelDownload(_ sender: Any?) {
            CollectionGridActionSupport.withFirstSelectedVideo(selectedVideoIds: renderedSelectedVideoIds) {
                VideoDownloadManager.shared.cancel(videoId: $0)
            }
        }

        @objc private func contextDeleteDownload(_ sender: Any?) {
            CollectionGridActionSupport.withFirstSelectedVideo(selectedVideoIds: renderedSelectedVideoIds) {
                VideoDownloadManager.shared.deleteDownload(videoId: $0)
            }
        }

        private func showPlaylistPopup(mode: CollectionGridPlaylistShortcutMode) {
            CollectionGridActionSupport.showPlaylistPopup(
                mode: mode,
                store: store,
                collectionView: collectionView,
                selectedVideoIds: renderedSelectedVideoIds,
                orderedIndexPaths: indexPaths(for: renderedSelectedVideoIds).sorted(),
                frameForIndexPath: { [weak collectionView] indexPath in
                    collectionView?.layoutAttributesForItem(at: indexPath)?.frame
                },
                target: self,
                saveSelector: #selector(contextSaveToPlaylist(_:)),
                moveSelector: #selector(contextMoveToPlaylist(_:))
            )
        }

        private func installActionObserversIfNeeded() {
            commandObservers.install(
                saveToWatchLater: { [weak self] in self?.handleSaveToWatchLaterShortcut() },
                saveToPlaylist: { [weak self] in self?.handleSaveToPlaylistShortcut() },
                moveToPlaylist: { [weak self] in self?.handleMoveToPlaylistShortcut() },
                dismissCandidates: { [weak self] in self?.handleDismissShortcut() },
                notInterested: { [weak self] in self?.handleNotInterestedShortcut() },
                openOnYouTube: { [weak self] in self?.handleOpenSelectedShortcut() },
                clearSelection: { [weak self] in self?.handleClearSelectionShortcut() },
                toggleShowDismissed: { [weak self] in self?.handleToggleShowDismissedShortcut() }
            )
        }

        private func detachFromContainer() {
            collectionView?.dataSource = nil
            collectionView?.delegate = nil
            container?.onReadyForFlush = nil
            container?.onBoundsChanged = nil
            container = nil
            collectionView = nil
        }
    }
}
