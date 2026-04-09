import SwiftUI
import AppKit
import TaggingKit

// MARK: - SwiftUI Wrapper

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
            onSelect: { videoId in
                store.selectedVideoId = videoId
            },
            onSelectionChange: { primary, ids in
                store.updateSelection(primary: primary, all: ids)
            },
            onClearScrollRequest: {
                displaySettings.scrollToTopicRequested = nil
                displaySettings.scrollToSectionRequested = nil
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
        .onChange(of: store.candidateRefreshToken) { _, _ in loadAndFilter() }
    }

    private func loadAndFilter() {
        let result = GridSectionBuilder.build(
            context: GridSectionBuilder.Context(
                topics: store.topics,
                parsedQuery: store.parsedQuery,
                selectedSubtopicId: store.selectedSubtopicId,
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

        store.searchResultCount = result.searchResultCount
        sections = result.sections
        sectionGeneration += 1
    }

    private func mapVideos(_ viewModels: [VideoViewModel]) -> [VideoGridItemModel] {
        viewModels.map { v in
            VideoGridItemModel(
                id: v.videoId, title: v.title, channelName: v.channelName,
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
    let onSelect: (String) -> Void
    let onSelectionChange: (String?, Set<String>) -> Void
    let onClearScrollRequest: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onSelectionChange: onSelectionChange)
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
            DispatchQueue.main.async {
                onClearScrollRequest()
            }
        }

        if let sectionId = scrollToSectionRequested {
            coordinator.enqueueScroll(toSectionId: sectionId)
            DispatchQueue.main.async {
                onClearScrollRequest()
            }
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
        private var actionObservers: [NSObjectProtocol] = []

        var cacheDir: URL = URL(fileURLWithPath: "/tmp")
        var thumbnailSize: Double = 220
        var showMetadata: Bool = true
        var onSelect: (String) -> Void
        var onSelectionChange: (String?, Set<String>) -> Void

        init(onSelect: @escaping (String) -> Void, onSelectionChange: @escaping (String?, Set<String>) -> Void) {
            self.onSelect = onSelect
            self.onSelectionChange = onSelectionChange
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
            container.collectionView.onFavoritePlaylistShortcut = { [weak self] index in
                self?.handleFavoritePlaylistShortcut(index: index)
            }
            container.onReadyForFlush = { [weak self] in
                self?.flushIfReady()
            }
            container.onBoundsChanged = { [weak self] in
                self?.refreshVisibleHeaders()
                self?.refreshTopicScrollProgress()
                self?.refreshViewportContext()
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
            pendingScrollTopicId = topicId
        }

        func enqueueScroll(toSectionId sectionId: String) {
            pendingScrollSectionId = sectionId
        }

        func flushIfReady() {
            guard let container, let collectionView, container.isReadyForCollectionWork else { return }

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
                pendingScrollTopicId = nil
                didApplyScroll = scrollToTopic(topicId)
            }

            if let sectionId = pendingScrollSectionId {
                pendingScrollSectionId = nil
                didApplyScroll = scrollToSection(sectionId) || didApplyScroll
            }

            if renderedSelectedVideoId != pendingSelectedVideoId || renderedSelectedVideoIds != pendingSelectedVideoIds || shouldReload || shouldInvalidateLayout || didApplyScroll {
                renderedSelectedVideoId = pendingSelectedVideoId
                renderedSelectedVideoIds = pendingSelectedVideoIds
                applySelectionToCollectionView()
                refreshVisibleItems()
            }

            refreshTopicScrollProgress()
            refreshViewportContext()
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

        @discardableResult
        private func scrollToTopic(_ topicId: Int64) -> Bool {
            guard let collectionView,
                  collectionView.numberOfSections > 0,
                  let sectionIndex = renderedSections.firstIndex(where: { $0.topicId == topicId }),
                  sectionIndex < collectionView.numberOfSections else { return false }

            return scrollToSectionIndex(sectionIndex)
        }

        @discardableResult
        private func scrollToSection(_ sectionId: String) -> Bool {
            guard let collectionView,
                  collectionView.numberOfSections > 0,
                  let sectionIndex = renderedSections.firstIndex(where: { $0.id == sectionId }),
                  sectionIndex < collectionView.numberOfSections else { return false }

            return scrollToSectionIndex(sectionIndex)
        }

        @discardableResult
        private func scrollToSectionIndex(_ sectionIndex: Int) -> Bool {
            guard let collectionView else { return false }
            let itemCount = collectionView.numberOfItems(inSection: sectionIndex)
            if itemCount > 0 {
                let indexPath = IndexPath(item: 0, section: sectionIndex)
                collectionView.scrollToItems(at: Set([indexPath]), scrollPosition: .top)

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
                    : store?.recentCandidateVideosForTopic(section.topicId) ?? [])
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
                sourceVideos = store.recentCandidateVideosForAllTopics()
            } else {
                sourceVideos = store.recentCandidateVideosForTopic(section.topicId)
            }

            var bestByChannelId: [String: ChannelRecord] = [:]
            for video in sourceVideos where !video.isPlaceholder {
                let channelId = if let channelId = video.channelId, !channelId.isEmpty {
                    channelId
                } else {
                    "watch-\(video.channelName ?? "unknown")"
                }
                if let known = store.channelsForTopic(section.topicId).first(where: { $0.channelId == video.channelId }) {
                    bestByChannelId[channelId] = known
                    continue
                }

                if bestByChannelId[channelId] == nil {
                    bestByChannelId[channelId] = ChannelRecord(
                        channelId: channelId,
                        name: video.channelName ?? "Unknown Creator",
                        handle: nil,
                        channelUrl: video.channelId.flatMap { "https://www.youtube.com/channel/\($0)" },
                        iconUrl: video.channelIconUrl,
                        iconData: nil,
                        subscriberCount: nil,
                        description: nil,
                        videoCountTotal: nil,
                        fetchedAt: nil
                    )
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
            let visibleRect = collectionView.visibleRect
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
            guard let store,
                  store.pageDisplayMode == .saved,
                  let collectionView,
                  let scrollView = collectionView.enclosingScrollView else {
                store?.updateViewportContext(topicId: nil, subtopicId: nil, creatorSectionId: nil)
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
                saveToWatchLater.keyEquivalent = "w"
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

                    let currentPlaylists = selectedVideoIds
                        .flatMap { store.playlistsForVideo($0).map(\.playlistId) }
                    let removablePlaylistIds = Set(currentPlaylists)

                    let removeMenu = NSMenu(title: "Remove from Playlist")
                    for playlist in store.knownPlaylists().filter({ removablePlaylistIds.contains($0.playlistId) }) {
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

                    if selectionCount == 1 {
                        let showMenu = NSMenu(title: "Show in Playlists")
                        for playlist in store.playlistsForVideo(selectedItems[0].id) {
                            let item = NSMenuItem(title: playlist.title, action: #selector(contextShowInPlaylist(_:)), keyEquivalent: "")
                            item.representedObject = playlist
                            item.target = self
                            showMenu.addItem(item)
                        }
                        let showItem = NSMenuItem(title: "Show in Playlists", action: nil, keyEquivalent: "")
                        showItem.submenu = showMenu
                        showItem.isEnabled = !showMenu.items.isEmpty
                        menu.addItem(showItem)
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

        private func handleFavoritePlaylistShortcut(index: Int) {
            guard let store, !renderedSelectedVideoIds.isEmpty else { return }
            let favorites = Array(store.knownPlaylists().prefix(9))
            guard favorites.indices.contains(index) else {
                NSSound.beep()
                return
            }
            let playlist = favorites[index]
            if let topicId = store.selectedTopicId,
               renderedSelectedVideoIds.allSatisfy(isCandidateVideo) {
                store.saveCandidatesToPlaylist(topicId: topicId, videoIds: Array(renderedSelectedVideoIds), playlist: playlist)
            } else {
                store.saveVideosToPlaylist(videoIds: Array(renderedSelectedVideoIds), playlist: playlist)
            }
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

        @objc private func contextShowInPlaylist(_ sender: NSMenuItem) {
            guard let store,
                  let playlist = sender.representedObject as? PlaylistRecord else { return }
            store.applyPlaylistFilter(playlist)
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
                },
                center.addObserver(forName: AppCommandBridge.saveToFavoritePlaylist, object: nil, queue: .main) { [weak self] note in
                    let index = note.userInfo?["index"] as? Int ?? -1
                    Task { @MainActor in self?.handleFavoritePlaylistShortcut(index: index) }
                }
            ]
        }
    }
}

private final class CollectionGridContainerView: NSView {
    let scrollView = NSScrollView()
    let collectionView = ClickableCollectionView()
    let flowLayout = NSCollectionViewFlowLayout()

    var onReadyForFlush: (() -> Void)?
    var onBoundsChanged: (() -> Void)?

    private var flushScheduled = false
    private var lastContentWidth: CGFloat = 0
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    private var initialLayoutTask: Task<Void, Never>?

    var isReadyForCollectionWork: Bool {
        window != nil && contentWidth > 1
    }

    private var contentWidth: CGFloat {
        scrollView.contentView.bounds.width
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViewHierarchy()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installBoundsObserverIfNeeded()
            scheduleInitialLayoutStabilization()
        } else {
            removeBoundsObserver()
            cancelInitialLayoutStabilization()
        }
        scheduleFlushIfReady()
    }

    deinit {
        initialLayoutTask?.cancel()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    override func layout() {
        super.layout()
        handleWidthChangeIfNeeded()
    }

    func scheduleFlushIfReady() {
        guard isReadyForCollectionWork, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.isReadyForCollectionWork else { return }
            self.onReadyForFlush?()
        }
    }

    private func setupViewHierarchy() {
        wantsLayer = false

        flowLayout.scrollDirection = .vertical
        flowLayout.sectionHeadersPinToVisibleBounds = true

        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        collectionView.autoresizingMask = [.width]
        collectionView.register(VideoItemCell.self, forItemWithIdentifier: VideoItemCell.identifier)
        collectionView.register(
            CollectionSectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: CollectionSectionHeaderView.reuseIdentifier
        )

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.contentView.postsBoundsChangedNotifications = true

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func installBoundsObserverIfNeeded() {
        guard boundsObserver == nil else { return }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWidthChangeIfNeeded()
                self?.onBoundsChanged?()
            }
        }
    }

    private func removeBoundsObserver() {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
    }

    private func scheduleInitialLayoutStabilization() {
        guard initialLayoutTask == nil else { return }
        let delays: [TimeInterval] = [0.0, 0.05, 0.15, 0.3]
        initialLayoutTask = Task { @MainActor [weak self] in
            defer { self?.initialLayoutTask = nil }
            for delay in delays {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled, let self else { return }
                self.forceRelayoutPass()
            }
        }
    }

    private func cancelInitialLayoutStabilization() {
        initialLayoutTask?.cancel()
        initialLayoutTask = nil
    }

    private func forceRelayoutPass() {
        let width = contentWidth
        guard width > 1 else { return }
        lastContentWidth = width
        collectionView.frame.size.width = width
        flowLayout.invalidateLayout()
        collectionView.needsLayout = true
        collectionView.layoutSubtreeIfNeeded()
        scheduleFlushIfReady()
    }

    private func handleWidthChangeIfNeeded() {
        let width = contentWidth
        guard abs(width - lastContentWidth) > 0.5 else { return }
        lastContentWidth = width
        collectionView.frame.size.width = width
        flowLayout.invalidateLayout()
        scheduleFlushIfReady()
    }
}

enum CollectionSectionHeaderModel {
    case topic(
        name: String,
        count: Int,
        totalCount: Int?,
        topicId: Int64,
        scrollProgress: Double,
        highlightTerms: [String],
        displayMode: TopicDisplayMode,
        channels: [ChannelRecord],
        selectedChannelId: String?,
        videoCountForChannel: (String) -> Int,
        hasRecentContent: (String) -> Bool,
        latestPublishedAtForChannel: (String) -> Date?,
        onSelectChannel: (String) -> Void
    )
    case creator(
        channelName: String,
        channelIconUrl: URL?,
        channelUrl: URL?,
        count: Int,
        totalCount: Int?,
        topicNames: [String],
        sectionId: String,
        scrollProgress: Double,
        highlightTerms: [String],
        onInspect: () -> Void
    )

    var height: CGFloat {
        switch self {
        case let .topic(name: _, count: _, totalCount: _, topicId: _, scrollProgress: _, highlightTerms: _, displayMode: _, channels: channels, selectedChannelId: _, videoCountForChannel: _, hasRecentContent: _, latestPublishedAtForChannel: _, onSelectChannel: _):
            return channels.isEmpty ? 48 : 112
        case .creator:
            return 56
        }
    }
}

// MARK: - Video Cell (custom NSCollectionViewItem subclass)

final class VideoItemCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("VideoItemCell")

    private var hostingView: NSHostingView<VideoCellContent>?
    var representedIndexPath: IndexPath?
    var onHoverChange: ((Bool) -> Void)? {
        didSet {
            (view as? HoverTrackingView)?.onHoverChange = onHoverChange
        }
    }
    var onContextMenuRequest: ((NSPoint) -> NSMenu?)? {
        didSet {
            (view as? HoverTrackingView)?.onContextMenuRequest = onContextMenuRequest
        }
    }

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func loadView() {
        let trackingView = HoverTrackingView(frame: .zero)
        trackingView.onHoverChange = onHoverChange
        trackingView.onContextMenuRequest = onContextMenuRequest
        self.view = trackingView
    }

    func configure(
        video: VideoGridItemModel,
        cacheDir: URL,
        thumbnailSize: Double,
        showMetadata: Bool,
        isSelected: Bool,
        highlightTerms: [String]
    ) {
        let content = VideoCellContent(
            video: video, cacheDir: cacheDir,
            thumbnailSize: thumbnailSize, showMetadata: showMetadata,
            isSelected: isSelected,
            highlightTerms: highlightTerms
        )
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hv = NSHostingView(rootView: content)
            hv.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hv)
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: view.topAnchor),
                hv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            self.hostingView = hv
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedIndexPath = nil
        onHoverChange = nil
        onContextMenuRequest = nil
    }
}

private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onContextMenuRequest: ((NSPoint) -> NSMenu?)?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control),
           let menu = contextMenu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(for: event) ?? super.menu(for: event)
    }

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return onContextMenuRequest?(point)
    }
}

// MARK: - Video Cell SwiftUI Content

private struct VideoCellContent: View {
    let video: VideoGridItemModel
    let cacheDir: URL
    let thumbnailSize: Double
    let showMetadata: Bool
    let isSelected: Bool
    var highlightTerms: [String] = []

    private var cornerRadius: CGFloat { GridConstants.cornerRadius(for: thumbnailSize) }
    private var metadataLine: String? {
        let parts = [video.viewCount, video.publishedAt].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: showMetadata ? GridConstants.metadataSpacing(for: thumbnailSize) : 2) {
            if video.isPlaceholder {
                placeholderCard
            } else {
                standardCard
            }
        }
        .padding(showMetadata ? GridConstants.cardPadding(for: thumbnailSize) : 2)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                .fill(Color.white.opacity(isSelected ? GridConstants.hoverBackgroundOpacity : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                .stroke(Color.accentColor, lineWidth: isSelected ? GridConstants.selectionBorderWidth : 0)
        )
    }

    private var standardCard: some View {
        Group {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(videoId: video.id, thumbnailUrl: video.thumbnailUrl, cacheDir: cacheDir)
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

                if let stateTag = video.stateTag {
                    VStack {
                        HStack {
                            Text(stateTag)
                                .font(GridConstants.metadataFont(for: thumbnailSize).weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.92), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(GridConstants.durationPadding(for: thumbnailSize))
                }

                if let duration = video.duration {
                    Text(duration)
                        .font(.system(size: GridConstants.durationFontSize(for: thumbnailSize), weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: GridConstants.durationBadgeCornerRadius))
                        .padding(GridConstants.durationPadding(for: thumbnailSize))
                }
            }

            if showMetadata {
                Text(video.title)
                    .font(GridConstants.titleFont(for: thumbnailSize))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                if let channel = video.channelName {
                    Text(channel)
                        .font(GridConstants.channelFont(for: thumbnailSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let metadataLine {
                    Text(metadataLine)
                        .font(GridConstants.metadataFont(for: thumbnailSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else if !highlightTerms.isEmpty {
                HighlightedText(video.title, terms: highlightTerms)
                    .font(GridConstants.titleFont(for: thumbnailSize))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
    }

    private var placeholderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [8, 6]))
                        .foregroundStyle(Color.accentColor.opacity(0.35))
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text("Watch")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)

            Text(video.title)
                .font(GridConstants.titleFont(for: thumbnailSize))
                .foregroundStyle(.primary)

            if let message = video.placeholderMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Section Header (custom NSView subclass)

final class CollectionSectionHeaderView: NSView, NSCollectionViewElement {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SectionHeader")

    private var hostingView: NSHostingView<SectionHeaderContent>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(model: CollectionSectionHeaderModel) {
        let content = SectionHeaderContent(model: model)
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hv = NSHostingView(rootView: content)
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: topAnchor),
                hv.leadingAnchor.constraint(equalTo: leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor),
                hv.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.hostingView = hv
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
    }
}

// MARK: - Section Header SwiftUI Content

private struct SectionHeaderContent: View {
    let model: CollectionSectionHeaderModel

    var body: some View {
        switch model {
        case let .topic(name, count, totalCount, topicId, scrollProgress, highlightTerms, displayMode, channels, selectedChannelId, videoCountForChannel, hasRecentContent, latestPublishedAtForChannel, onSelectChannel):
            VStack(spacing: 0) {
                SectionHeaderView(
                    name: name,
                    count: count,
                    totalCount: totalCount,
                    topicId: topicId,
                    progress: scrollProgress,
                    showProgress: displayMode != .watchCandidates,
                    highlightTerms: highlightTerms
                )
                .accessibilityIdentifier("topic-\(topicId)")

                if !channels.isEmpty {
                    CreatorCirclesBar(
                        channels: channels,
                        selectedChannelId: selectedChannelId,
                        topicId: topicId,
                        collapseLowCountCreators: displayMode != .watchCandidates,
                        prioritizeRecency: displayMode == .watchCandidates,
                        videoCountForChannel: videoCountForChannel,
                        hasRecentContent: hasRecentContent,
                        latestPublishedAtForChannel: latestPublishedAtForChannel,
                        onSelect: onSelectChannel
                    )
                }
            }
        case let .creator(channelName, channelIconUrl, channelUrl, count, totalCount, topicNames, sectionId, scrollProgress, highlightTerms, onInspect):
            CreatorSectionHeaderView(
                channelName: channelName,
                channelIconUrl: channelIconUrl,
                channelUrl: channelUrl,
                count: count,
                totalCount: totalCount,
                topicNames: topicNames,
                sectionId: sectionId,
                progress: scrollProgress,
                highlightTerms: highlightTerms
            )
            .onTapGesture(perform: onInspect)
            .contextMenu {
                if let channelUrl {
                    Button("Open Channel on YouTube") {
                        NSWorkspace.shared.open(channelUrl)
                    }
                }
            }
        }
    }
}

private final class ClickableCollectionView: NSCollectionView {
    var onDoubleClickItem: ((IndexPath) -> Void)?
    var onContextMenuRequest: ((NSPoint) -> NSMenu?)?
    var onMarqueeSelection: ((NSRect, NSEvent.ModifierFlags, Bool) -> Void)?
    var onSaveToWatchLaterShortcut: (() -> Void)?
    var onSaveToPlaylistShortcut: (() -> Void)?
    var onMoveToPlaylistShortcut: (() -> Void)?
    var onDismissShortcut: (() -> Void)?
    var onNotInterestedShortcut: (() -> Void)?
    var onOpenSelectedShortcut: (() -> Void)?
    var onClearSelectionShortcut: (() -> Void)?
    var onFavoritePlaylistShortcut: ((Int) -> Void)?

    private let marqueeLayer = CAShapeLayer()
    private var marqueeStartPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown, event.clickCount == 1, indexPathForItem(at: point) == nil {
            marqueeStartPoint = point
            updateMarqueeSelection(currentPoint: point, modifiers: event.modifierFlags, finalize: false)
            return
        }

        super.mouseDown(with: event)

        guard event.clickCount == 2 else { return }
        guard let indexPath = indexPathForItem(at: point) else { return }
        onDoubleClickItem?(indexPath)
    }

    override func mouseDragged(with event: NSEvent) {
        guard marqueeStartPoint != nil else {
            super.mouseDragged(with: event)
            return
        }
        let currentPoint = convert(event.locationInWindow, from: nil)
        updateMarqueeSelection(currentPoint: currentPoint, modifiers: event.modifierFlags, finalize: false)
    }

    override func mouseUp(with event: NSEvent) {
        if marqueeStartPoint != nil {
            let currentPoint = convert(event.locationInWindow, from: nil)
            updateMarqueeSelection(currentPoint: currentPoint, modifiers: event.modifierFlags, finalize: true)
            clearMarqueeSelection()
            return
        }
        super.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return onContextMenuRequest?(point)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers.isEmpty,
           key == "w" {
            onSaveToWatchLaterShortcut?()
            return
        }
        if modifiers.isEmpty,
           key == "p" {
            onSaveToPlaylistShortcut?()
            return
        }
        if modifiers == [.shift],
           key == "p" {
            onMoveToPlaylistShortcut?()
            return
        }
        if modifiers.isEmpty,
           key == "d" {
            onDismissShortcut?()
            return
        }
        if modifiers.isEmpty,
           key == "n" {
            onNotInterestedShortcut?()
            return
        }
        if modifiers.isEmpty,
           event.keyCode == 36 || event.keyCode == 76 {
            onOpenSelectedShortcut?()
            return
        }
        if modifiers.isEmpty,
           event.keyCode == 53 {
            onClearSelectionShortcut?()
            return
        }
        if modifiers.isEmpty,
           let key,
           let digit = Int(key),
           (1...9).contains(digit) {
            onFavoritePlaylistShortcut?(digit - 1)
            return
        }
        super.keyDown(with: event)
    }

    private func updateMarqueeSelection(currentPoint: NSPoint, modifiers: NSEvent.ModifierFlags, finalize: Bool) {
        guard let marqueeStartPoint else { return }
        let rect = NSRect(
            x: min(marqueeStartPoint.x, currentPoint.x),
            y: min(marqueeStartPoint.y, currentPoint.y),
            width: abs(currentPoint.x - marqueeStartPoint.x),
            height: abs(currentPoint.y - marqueeStartPoint.y)
        )

        if marqueeLayer.superlayer == nil {
            wantsLayer = true
            marqueeLayer.fillColor = NSColor.selectedControlColor.withAlphaComponent(0.12).cgColor
            marqueeLayer.strokeColor = NSColor.selectedControlColor.withAlphaComponent(0.75).cgColor
            marqueeLayer.lineWidth = 1
            marqueeLayer.lineDashPattern = [6, 4]
            layer?.addSublayer(marqueeLayer)
        }

        marqueeLayer.path = CGPath(rect: rect, transform: nil)
        onMarqueeSelection?(rect, modifiers, finalize)
    }

    private func clearMarqueeSelection() {
        marqueeStartPoint = nil
        marqueeLayer.removeFromSuperlayer()
        marqueeLayer.path = nil
    }
}
