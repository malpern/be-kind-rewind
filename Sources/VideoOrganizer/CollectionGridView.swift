import SwiftUI
import AppKit
import TaggingKit

// MARK: - SwiftUI Wrapper (matches AllVideosGridView interface)

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
            scrollToTopicRequested: displaySettings.scrollToTopicRequested,
            scrollToSectionRequested: displaySettings.scrollToSectionRequested,
            onSelect: { videoId in
                store.selectedVideoId = videoId
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
        .onChange(of: store.topicDisplayModes) { _, _ in loadAndFilter() }
        .onChange(of: store.candidateRefreshToken) { _, _ in loadAndFilter() }
    }

    // MARK: - Section Computation (replicated from AllVideosGridView)

    private func loadAndFilter() {
        var baseSections: [TopicSection] = []

        for topic in store.topics {
            let displayMode = store.displayMode(for: topic.id)
            if topic.subtopics.isEmpty {
                let videos = videosForTopic(topic.id, name: topic.name, displayMode: displayMode)
                if !videos.isEmpty {
                    baseSections.append(TopicSection(topicId: topic.id, topicName: topic.name, videos: videos, displayMode: displayMode))
                }
            } else {
                var allVideos: [VideoGridItemModel] = []
                var subtopicMap: [String: Int64] = [:]
                if displayMode == .saved {
                    for sub in topic.subtopics {
                        let videos = mapVideos(store.videosForTopic(sub.id))
                        for v in videos { subtopicMap[v.id] = sub.id }
                        allVideos.append(contentsOf: videos)
                    }
                    let parentVideos = mapVideos(store.videosForTopic(topic.id))
                    allVideos.append(contentsOf: parentVideos)
                } else {
                    allVideos = videosForTopic(topic.id, name: topic.name, displayMode: displayMode)
                }
                if !allVideos.isEmpty {
                    baseSections.append(TopicSection(topicId: topic.id, topicName: topic.name, videos: allVideos, videoSubtopicMap: subtopicMap, displayMode: displayMode))
                }
            }
        }

        let query = store.parsedQuery
        var result: [TopicSection]
        if query.isEmpty {
            result = baseSections
            store.searchResultCount = 0
        } else {
            result = []
            for section in baseSections {
                if query.matches(fields: [section.topicName]) {
                    result.append(TopicSection(topicId: section.topicId, topicName: section.topicName, videos: section.videos, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap, displayMode: section.displayMode))
                } else {
                    let matching = section.videos.filter { video in
                        query.matches(fields: [video.title, video.channelName ?? "", section.topicName])
                    }
                    if !matching.isEmpty {
                        result.append(TopicSection(topicId: section.topicId, topicName: section.topicName, videos: matching, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap, displayMode: section.displayMode))
                    }
                }
            }
            store.searchResultCount = result.reduce(0) { $0 + $1.videos.count }
        }

        if let subId = store.selectedSubtopicId {
            result = result.compactMap { section in
                guard section.displayMode == .saved else { return section }
                let filtered = section.videos.filter { section.videoSubtopicMap[$0.id] == subId }
                guard !filtered.isEmpty else { return nil }
                return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: filtered, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap, displayMode: section.displayMode)
            }
        }

        if let channelId = store.selectedChannelId {
            result = result.compactMap { section in
                guard section.displayMode == .saved else { return section }
                let filtered = section.videos.filter { $0.channelId == channelId }
                guard !filtered.isEmpty else { return nil }
                return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: filtered, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap, displayMode: section.displayMode)
            }
        }

        if store.selectedPlaylistId != nil {
            result = result.compactMap { section in
                guard section.displayMode == .saved else { return section }
                let filtered = section.videos.filter { store.videoIsInSelectedPlaylist($0.id) }
                guard !filtered.isEmpty else { return nil }
                return TopicSection(
                    topicId: section.topicId,
                    topicName: section.topicName,
                    videos: filtered,
                    totalCount: section.videos.count,
                    videoSubtopicMap: section.videoSubtopicMap,
                    displayMode: section.displayMode
                )
            }
        }

        if let sortOrder = displaySettings.sortOrder {
            if sortOrder == .creator {
                result = result.flatMap { section in
                    section.displayMode == .saved ? groupByCreator(section: section, ascending: displaySettings.sortAscending) : [section]
                }
            } else {
                result = result.map { section in
                    guard section.displayMode == .saved else { return section }
                    let sorted = sortVideos(section.videos, by: sortOrder, ascending: displaySettings.sortAscending)
                    return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: sorted, totalCount: section.totalCount, videoSubtopicMap: section.videoSubtopicMap, displayMode: section.displayMode)
                }
            }
        }

        sections = result
        sectionGeneration += 1
    }

    private func mapVideos(_ viewModels: [VideoViewModel]) -> [VideoGridItemModel] {
        viewModels.map { v in
            VideoGridItemModel(
                id: v.videoId, title: v.title, channelName: v.channelName,
                thumbnailUrl: v.thumbnailUrl, viewCount: v.viewCount,
                publishedAt: v.publishedAt, duration: v.duration,
                channelIconUrl: v.channelIconUrl.flatMap { URL(string: $0) },
                channelId: v.channelId,
                isPlaceholder: false,
                placeholderMessage: nil
            )
        }
    }

    private func videosForTopic(_ topicId: Int64, name: String, displayMode: TopicDisplayMode) -> [VideoGridItemModel] {
        switch displayMode {
        case .saved:
            return mapVideos(store.videosForTopic(topicId))
        case .watchCandidates:
            return store.candidateVideosForTopic(topicId).map {
                VideoGridItemModel(
                    id: $0.videoId,
                    title: $0.title,
                    channelName: $0.channelName,
                    thumbnailUrl: $0.thumbnailUrl,
                    viewCount: $0.viewCount,
                    publishedAt: $0.publishedAt,
                    duration: $0.duration,
                    channelIconUrl: $0.channelIconUrl.flatMap(URL.init(string:)),
                    channelId: $0.channelId,
                    isPlaceholder: $0.isPlaceholder,
                    placeholderMessage: $0.secondaryText
                )
            }
        }
    }

    private func groupByCreator(section: TopicSection, ascending: Bool) -> [TopicSection] {
        GridSectionLogic.groupByCreator(
            section: section,
            ascending: ascending,
            channelCounts: store.channelCounts,
            includeTopicMarker: true
        )
    }

    private func sortVideos(_ videos: [VideoGridItemModel], by order: SortOrder, ascending: Bool) -> [VideoGridItemModel] {
        GridSectionLogic.sortVideos(videos, by: order, ascending: ascending)
    }

    private func parseViewCount(_ str: String?) -> Int {
        GridSectionLogic.parseViewCount(str)
    }

    private func parseAge(_ str: String?) -> Int {
        GridSectionLogic.parseAge(str)
    }

    private func parseDuration(_ str: String?) -> Int {
        GridSectionLogic.parseDuration(str)
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
    let scrollToTopicRequested: Int64?
    let scrollToSectionRequested: String?
    let onSelect: (String) -> Void
    let onClearScrollRequest: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
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
        private var needsLayoutInvalidation = false
        private var renderedContentWidth: CGFloat = 0

        var cacheDir: URL = URL(fileURLWithPath: "/tmp")
        var thumbnailSize: Double = 220
        var showMetadata: Bool = true
        var onSelect: (String) -> Void

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
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
            container.onReadyForFlush = { [weak self] in
                self?.flushIfReady()
            }
        }

        func applySnapshot(
            store: OrganizerStore,
            sections: [TopicSection],
            generation: Int,
            cacheDir: URL,
            thumbnailSize: Double,
            showMetadata: Bool,
            selectedVideoId: String?,
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

            if renderedSelectedVideoId != pendingSelectedVideoId || shouldReload || shouldInvalidateLayout || didApplyScroll {
                renderedSelectedVideoId = pendingSelectedVideoId
                refreshVisibleItems()
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
            guard let indexPath = indexPaths.first,
                  indexPath.section < renderedSections.count,
                  indexPath.item < renderedSections[indexPath.section].videos.count else { return }

            let video = renderedSections[indexPath.section].videos[indexPath.item]
            guard !video.isPlaceholder else { return }
            pendingSelectedVideoId = video.id
            renderedSelectedVideoId = video.id
            onSelect(video.id)
            refreshVisibleItems()
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
            let height = headerModel(for: renderedSections[section]).height
            return NSSize(width: max(collectionView.bounds.width, 1), height: height)
        }

        // MARK: Helpers

        private func configure(cell: VideoItemCell, at indexPath: IndexPath) {
            guard indexPath.section < renderedSections.count,
                  indexPath.item < renderedSections[indexPath.section].videos.count else { return }

            let video = renderedSections[indexPath.section].videos[indexPath.item]
            cell.representedIndexPath = indexPath
            cell.configure(
                video: video,
                cacheDir: cacheDir,
                thumbnailSize: thumbnailSize,
                showMetadata: showMetadata,
                isSelected: video.id == renderedSelectedVideoId
            )
        }

        private func refreshVisibleItems() {
            guard let collectionView else { return }
            for item in collectionView.visibleItems() {
                guard let cell = item as? VideoItemCell,
                      let indexPath = cell.representedIndexPath else { continue }
                configure(cell: cell, at: indexPath)
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
            if let creatorName = section.creatorName {
                return .creator(
                    channelName: creatorName,
                    channelIconUrl: section.channelIconUrl,
                    count: section.videos.count,
                    totalCount: section.totalCount,
                    topicNames: section.topicNames,
                    sectionId: section.id,
                    highlightTerms: store?.parsedQuery.includeTerms ?? [],
                    onInspect: { [weak store] in
                        store?.inspectedCreatorName = creatorName
                    }
                )
            }

            return .topic(
                name: section.topicName,
                count: section.headerCountOverride ?? section.videos.count,
                totalCount: section.totalCount,
                topicId: section.topicId,
                highlightTerms: store?.parsedQuery.includeTerms ?? [],
                displayMode: section.displayMode,
                candidateProgress: store?.candidateProgress(for: section.topicId) ?? 0,
                isCandidateLoading: store?.candidateLoadingTopics.contains(section.topicId) ?? false,
                candidateProgressTitle: store?.candidateProgressTitle(for: section.topicId),
                candidateProgressDetail: store?.candidateProgressDetail(for: section.topicId),
                onSelectDisplayMode: { [weak store] mode in
                    Task { @MainActor in
                        await store?.activateDisplayMode(mode, for: section.topicId)
                    }
                },
                channels: section.displayMode == .saved ? (store?.channelsForTopic(section.topicId) ?? []) : [],
                selectedChannelId: section.displayMode == .saved ? store?.selectedChannelId : nil,
                videoCountForChannel: { [weak store] channelId in
                    store?.videoCountForChannel(channelId, inTopic: section.topicId) ?? 0
                },
                hasRecentContent: { [weak store] channelId in
                    store?.channelHasRecentContent(channelId, inTopic: section.topicId) ?? false
                },
                onSelectChannel: { [weak store] channelId in
                    guard let store else { return }
                    let channel = store.channelsForTopic(section.topicId).first(where: { $0.channelId == channelId })
                    if store.selectedChannelId == channelId {
                        store.inspectedCreatorName = nil
                    } else {
                        store.inspectedCreatorName = channel?.name
                    }
                    store.toggleChannelFilter(channelId)
                }
            )
        }

        private func openOnYouTube(_ video: VideoGridItemModel) {
            guard let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

private final class CollectionGridContainerView: NSView {
    let scrollView = NSScrollView()
    let collectionView = ClickableCollectionView()
    let flowLayout = NSCollectionViewFlowLayout()

    var onReadyForFlush: (() -> Void)?

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
        collectionView.allowsMultipleSelection = false
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
        highlightTerms: [String],
        displayMode: TopicDisplayMode,
        candidateProgress: Double,
        isCandidateLoading: Bool,
        candidateProgressTitle: String?,
        candidateProgressDetail: String?,
        onSelectDisplayMode: (TopicDisplayMode) -> Void,
        channels: [ChannelRecord],
        selectedChannelId: String?,
        videoCountForChannel: (String) -> Int,
        hasRecentContent: (String) -> Bool,
        onSelectChannel: (String) -> Void
    )
    case creator(
        channelName: String,
        channelIconUrl: URL?,
        count: Int,
        totalCount: Int?,
        topicNames: [String],
        sectionId: String,
        highlightTerms: [String],
        onInspect: () -> Void
    )

    var height: CGFloat {
        switch self {
        case let .topic(name: _, count: _, totalCount: _, topicId: _, highlightTerms: _, displayMode: _, candidateProgress: _, isCandidateLoading: isCandidateLoading, candidateProgressTitle: _, candidateProgressDetail: _, onSelectDisplayMode: _, channels: channels, selectedChannelId: _, videoCountForChannel: _, hasRecentContent: _, onSelectChannel: _):
            if isCandidateLoading {
                return channels.isEmpty ? 104 : 168
            }
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
        self.view = NSView(frame: .zero)
    }

    func configure(video: VideoGridItemModel, cacheDir: URL, thumbnailSize: Double, showMetadata: Bool, isSelected: Bool) {
        let content = VideoCellContent(
            video: video, cacheDir: cacheDir,
            thumbnailSize: thumbnailSize, showMetadata: showMetadata,
            isSelected: isSelected
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
    }
}

// MARK: - Video Cell SwiftUI Content

private struct VideoCellContent: View {
    let video: VideoGridItemModel
    let cacheDir: URL
    let thumbnailSize: Double
    let showMetadata: Bool
    let isSelected: Bool

    private var cornerRadius: CGFloat { GridConstants.cornerRadius(for: thumbnailSize) }

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

            Text(video.title)
                .font(GridConstants.titleFont(for: thumbnailSize))
                .lineLimit(2)
                .foregroundStyle(.primary)

            if showMetadata, let channel = video.channelName {
                Text(channel)
                    .font(GridConstants.channelFont(for: thumbnailSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                        Text("Watch candidates")
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

final class CollectionSectionHeaderView: NSView {
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
        case let .topic(name, count, totalCount, topicId, highlightTerms, displayMode, candidateProgress, _, candidateProgressTitle, candidateProgressDetail, onSelectDisplayMode, channels, selectedChannelId, videoCountForChannel, hasRecentContent, onSelectChannel):
            VStack(spacing: 0) {
                SectionHeaderView(
                    name: name,
                    count: count,
                    totalCount: totalCount,
                    topicId: topicId,
                    progress: candidateProgress,
                    showProgress: false,
                    highlightTerms: highlightTerms,
                    displayMode: displayMode,
                    progressTitle: candidateProgressTitle,
                    progressDetail: candidateProgressDetail,
                    onDisplayModeChange: onSelectDisplayMode
                )
                .accessibilityIdentifier("topic-\(topicId)")

                if !channels.isEmpty {
                    CreatorCirclesBar(
                        channels: channels,
                        selectedChannelId: selectedChannelId,
                        topicId: topicId,
                        videoCountForChannel: videoCountForChannel,
                        hasRecentContent: hasRecentContent,
                        onSelect: onSelectChannel
                    )
                }
            }
        case let .creator(channelName, channelIconUrl, count, totalCount, topicNames, sectionId, highlightTerms, onInspect):
            CreatorSectionHeaderView(
                channelName: channelName,
                channelIconUrl: channelIconUrl,
                count: count,
                totalCount: totalCount,
                topicNames: topicNames,
                sectionId: sectionId,
                progress: 0,
                highlightTerms: highlightTerms
            )
            .onTapGesture(perform: onInspect)
            .onHover { hovering in
                if hovering {
                    onInspect()
                }
            }
        }
    }
}

private final class ClickableCollectionView: NSCollectionView {
    var onDoubleClickItem: ((IndexPath) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)

        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return }
        onDoubleClickItem?(indexPath)
    }
}
