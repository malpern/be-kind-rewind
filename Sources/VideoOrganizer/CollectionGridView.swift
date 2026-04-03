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
            onSelect: { videoId in
                store.selectedVideoId = videoId
            },
            onClearScrollRequest: {
                displaySettings.scrollToTopicRequested = nil
            }
        )
        .task {
            loadAndFilter()
            if store.selectedVideoId == nil,
               let first = sections.first?.videos.first {
                store.selectedVideoId = first.id
            }
        }
        .onChange(of: store.topics) { _, _ in loadAndFilter() }
        .onChange(of: store.searchText) { _, _ in loadAndFilter() }
        .onChange(of: displaySettings.sortOrder) { _, _ in loadAndFilter() }
        .onChange(of: displaySettings.sortAscending) { _, _ in loadAndFilter() }
        .onChange(of: store.selectedSubtopicId) { _, _ in loadAndFilter() }
        .onChange(of: store.selectedChannelId) { _, _ in loadAndFilter() }
    }

    // MARK: - Section Computation (replicated from AllVideosGridView)

    private func loadAndFilter() {
        var baseSections: [TopicSection] = []

        for topic in store.topics {
            if topic.subtopics.isEmpty {
                let videos = mapVideos(store.videosForTopic(topic.id))
                if !videos.isEmpty {
                    baseSections.append(TopicSection(topicId: topic.id, topicName: topic.name, videos: videos))
                }
            } else {
                var allVideos: [VideoGridItemModel] = []
                var subtopicMap: [String: Int64] = [:]
                for sub in topic.subtopics {
                    let videos = mapVideos(store.videosForTopic(sub.id))
                    for v in videos { subtopicMap[v.id] = sub.id }
                    allVideos.append(contentsOf: videos)
                }
                let parentVideos = mapVideos(store.videosForTopic(topic.id))
                allVideos.append(contentsOf: parentVideos)
                if !allVideos.isEmpty {
                    baseSections.append(TopicSection(topicId: topic.id, topicName: topic.name, videos: allVideos, videoSubtopicMap: subtopicMap))
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
                    result.append(TopicSection(topicId: section.topicId, topicName: section.topicName, videos: section.videos, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap))
                } else {
                    let matching = section.videos.filter { video in
                        query.matches(fields: [video.title, video.channelName ?? "", section.topicName])
                    }
                    if !matching.isEmpty {
                        result.append(TopicSection(topicId: section.topicId, topicName: section.topicName, videos: matching, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap))
                    }
                }
            }
            store.searchResultCount = result.reduce(0) { $0 + $1.videos.count }
        }

        if let subId = store.selectedSubtopicId {
            result = result.compactMap { section in
                let filtered = section.videos.filter { section.videoSubtopicMap[$0.id] == subId }
                guard !filtered.isEmpty else { return nil }
                return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: filtered, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap)
            }
        }

        if let channelId = store.selectedChannelId {
            result = result.compactMap { section in
                let filtered = section.videos.filter { $0.channelId == channelId }
                guard !filtered.isEmpty else { return nil }
                return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: filtered, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap)
            }
        }

        if let sortOrder = displaySettings.sortOrder {
            if sortOrder == .creator {
                result = result.flatMap { section in groupByCreator(section: section, ascending: displaySettings.sortAscending) }
            } else {
                result = result.map { section in
                    let sorted = sortVideos(section.videos, by: sortOrder, ascending: displaySettings.sortAscending)
                    return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: sorted, totalCount: section.totalCount, videoSubtopicMap: section.videoSubtopicMap)
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
                channelId: v.channelId
            )
        }
    }

    private func groupByCreator(section: TopicSection, ascending: Bool) -> [TopicSection] {
        var channelOrder: [String] = []
        var channelMap: [String: [VideoGridItemModel]] = [:]
        for video in section.videos {
            let name = video.channelName ?? "Unknown"
            if channelMap[name] == nil { channelOrder.append(name) }
            channelMap[name, default: []].append(video)
        }
        var grouped = channelOrder.compactMap { name -> (name: String, videos: [VideoGridItemModel])? in
            guard let videos = channelMap[name] else { return nil }
            return (name: name, videos: videos)
        }
        grouped.sort { a, b in ascending ? a.videos.count < b.videos.count : a.videos.count > b.videos.count }
        return grouped.map { group in
            let sorted = group.videos.sorted { a, b in parseAge(a.publishedAt) < parseAge(b.publishedAt) }
            let iconUrl = sorted.first(where: { $0.channelIconUrl != nil })?.channelIconUrl
            return TopicSection(
                topicId: section.topicId, topicName: section.topicName,
                videos: sorted, totalCount: store.channelCounts[group.name],
                videoSubtopicMap: section.videoSubtopicMap,
                creatorName: group.name, channelIconUrl: iconUrl, topicNames: [section.topicName]
            )
        }
    }

    private func sortVideos(_ videos: [VideoGridItemModel], by order: SortOrder, ascending: Bool) -> [VideoGridItemModel] {
        if order == .shuffle { return videos.shuffled() }
        return videos.sorted { a, b in
            let result: Bool
            switch order {
            case .views: result = parseViewCount(a.viewCount) > parseViewCount(b.viewCount)
            case .date: result = parseAge(a.publishedAt) < parseAge(b.publishedAt)
            case .duration: result = parseDuration(a.duration) > parseDuration(b.duration)
            case .creator:
                let aName = a.channelName ?? ""; let bName = b.channelName ?? ""
                result = aName == bName ? parseAge(a.publishedAt) < parseAge(b.publishedAt) : aName.localizedStandardCompare(bName) == .orderedAscending
            case .alphabetical: result = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .shuffle: result = false
            }
            return ascending ? !result : result
        }
    }

    private func parseViewCount(_ str: String?) -> Int {
        guard let str else { return 0 }
        let cleaned = str.replacingOccurrences(of: " views", with: "")
        if cleaned.hasSuffix("M") { return Int((Double(cleaned.dropLast()) ?? 0) * 1_000_000) }
        if cleaned.hasSuffix("K") { return Int((Double(cleaned.dropLast()) ?? 0) * 1_000) }
        return Int(cleaned) ?? 0
    }

    private func parseAge(_ str: String?) -> Int {
        guard let str else { return Int.max }
        if str == "today" { return 0 }
        let parts = str.split(separator: " ")
        guard parts.count >= 2, let num = Int(parts[0]) else { return Int.max }
        let unit = String(parts[1])
        if unit.hasPrefix("day") { return num }
        if unit.hasPrefix("month") { return num * 30 }
        if unit.hasPrefix("year") { return num * 365 }
        return Int.max
    }

    private func parseDuration(_ str: String?) -> Int {
        guard let str else { return 0 }
        let parts = str.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
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
    let scrollToTopicRequested: Int64?
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
        private var pendingSelectedVideoId: String?
        private var renderedSelectedVideoId: String?
        private var needsLayoutInvalidation = false

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

        func flushIfReady() {
            guard let container, let collectionView, container.isReadyForCollectionWork else { return }

            let shouldReload = renderedGeneration != pendingGeneration
            if shouldReload {
                renderedSections = pendingSections
                renderedGeneration = pendingGeneration
                collectionView.reloadData()
            }

            let shouldInvalidateLayout = needsLayoutInvalidation
            if shouldInvalidateLayout {
                needsLayoutInvalidation = false
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
            pendingSelectedVideoId = video.id
            renderedSelectedVideoId = video.id
            onSelect(video.id)
            refreshVisibleItems()
        }

        private func handleDoubleClick(at indexPath: IndexPath) {
            guard indexPath.section < renderedSections.count,
                  indexPath.item < renderedSections[indexPath.section].videos.count else { return }
            let video = renderedSections[indexPath.section].videos[indexPath.item]
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
                  sectionIndex < collectionView.numberOfSections,
                  collectionView.numberOfItems(inSection: sectionIndex) > 0 else { return false }

            let indexPath = IndexPath(item: 0, section: sectionIndex)
            collectionView.scrollToItems(at: Set([indexPath]), scrollPosition: .top)

            let video = renderedSections[sectionIndex].videos[0]
            pendingSelectedVideoId = video.id
            renderedSelectedVideoId = video.id
            onSelect(video.id)
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
                count: section.videos.count,
                totalCount: section.totalCount,
                topicId: section.topicId,
                highlightTerms: store?.parsedQuery.includeTerms ?? [],
                channels: store?.channelsForTopic(section.topicId) ?? [],
                selectedChannelId: store?.selectedChannelId,
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
        scheduleFlushIfReady()
    }

    override func layout() {
        super.layout()

        let width = contentWidth
        guard abs(width - lastContentWidth) > 0.5 else { return }
        lastContentWidth = width
        flowLayout.invalidateLayout()
        scheduleFlushIfReady()
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

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

enum CollectionSectionHeaderModel {
    case topic(
        name: String,
        count: Int,
        totalCount: Int?,
        topicId: Int64,
        highlightTerms: [String],
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
        case let .topic(_, _, _, _, _, channels, _, _, _, _):
            channels.isEmpty ? 48 : 112
        case .creator:
            56
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
        case let .topic(name, count, totalCount, topicId, highlightTerms, channels, selectedChannelId, videoCountForChannel, hasRecentContent, onSelectChannel):
            VStack(spacing: 0) {
                SectionHeaderView(
                    name: name,
                    count: count,
                    totalCount: totalCount,
                    topicId: topicId,
                    progress: 0,
                    showProgress: false,
                    highlightTerms: highlightTerms
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
