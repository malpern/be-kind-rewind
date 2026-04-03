import SwiftUI

struct AllVideosGridView: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache
    @Bindable var displaySettings: DisplaySettings
    @State private var sections: [TopicSection] = []
    @State private var allVideoIds: [String] = []
    @State private var cachedFilteredSections: [TopicSection] = []
    private var selectedVideoId: String? {
        get { store.selectedVideoId }
        nonmutating set { store.selectedVideoId = newValue }
    }
    @State private var containerWidth: CGFloat = 800
    @State private var sectionProgressValues: [String: Double] = [:]
    @State private var viewportHeight: CGFloat = 600
    @State private var suppressSidebarSync = false
    @State private var isScrolling = false
    @State private var scrollFadeTask: Task<Void, Never>?
    @State private var channelBarFocused = false  // true = arrow keys navigate channels, not videos
    @FocusState private var isFocused: Bool

    private var gridColumns: [GridItem] {
        let spacing: CGFloat = displaySettings.showMetadata ? GridConstants.metadataGridSpacing : GridConstants.compactGridSpacing
        let size = displaySettings.thumbnailSize
        return [GridItem(.adaptive(minimum: size, maximum: size), spacing: spacing)]
    }

    private var estimatedColumnCount: Int {
        let colWidth = displaySettings.thumbnailSize + GridConstants.columnSpacingEstimate
        let usableWidth = containerWidth - GridConstants.containerPaddingEstimate
        return max(1, Int(usableWidth / colWidth))
    }

    private var displayedSections: [TopicSection] { cachedFilteredSections }

    private var displayedVideoIds: [String] {
        displayedSections.flatMap { $0.videos.map(\.id) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent(proxy: proxy)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: ContainerWidthKey.self, value: geo.size.width)
                    }
                }
                .onPreferenceChange(ContainerWidthKey.self) { containerWidth = $0 }
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onKeyPress(.rightArrow) { if channelBarFocused { navigateChannel(by: 1); return .handled }; navigate(by: 1, proxy: proxy); return .handled }
                .onKeyPress(.leftArrow) { if channelBarFocused { navigateChannel(by: -1); return .handled }; navigate(by: -1, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "l")) { _ in if channelBarFocused { navigateChannel(by: 1); return .handled }; navigate(by: 1, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "h")) { _ in if channelBarFocused { navigateChannel(by: -1); return .handled }; navigate(by: -1, proxy: proxy); return .handled }
                .onKeyPress(.downArrow) { if channelBarFocused { enterVideoGrid(proxy: proxy); return .handled }; navigate(by: estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(.upArrow) { if tryEnterChannelBar(proxy: proxy) { return .handled }; navigate(by: -estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "j")) { _ in if channelBarFocused { enterVideoGrid(proxy: proxy); return .handled }; navigate(by: estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "k")) { _ in if tryEnterChannelBar(proxy: proxy) { return .handled }; navigate(by: -estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(.pageDown) { navigate(by: estimatedColumnCount * GridConstants.pageJumpRows, proxy: proxy); return .handled }
                .onKeyPress(.pageUp) { navigate(by: -estimatedColumnCount * GridConstants.pageJumpRows, proxy: proxy); return .handled }
                .onKeyPress(.home) { jumpToEdge(first: true, proxy: proxy); return .handled }
                .onKeyPress(.end) { jumpToEdge(first: false, proxy: proxy); return .handled }
                .onChange(of: selectedVideoId) { _, newId in
                    syncSidebarToVideo(newId)
                }
                .onChange(of: store.selectedTopicId) { _, newId in
                    scrollToTopic(newId, proxy: proxy)
                }
                .onChange(of: displaySettings.scrollToTopicRequested) { _, topicId in
                    guard let topicId else { return }
                    displaySettings.scrollToTopicRequested = nil
                    scrollToTopic(topicId, proxy: proxy)
                }
                .onChange(of: displaySettings.focusGridRequested) { _, requested in
                    guard requested else { return }
                    displaySettings.focusGridRequested = false
                    isFocused = true
                }
        }
        .task {
            loadSections()
            recomputeFilteredSections()
            isFocused = true
            if selectedVideoId == nil, let first = allVideoIds.first {
                selectedVideoId = first
            }
        }
        .onChange(of: store.topics) { _, _ in
            loadSections()
            recomputeFilteredSections()
        }
        .onChange(of: store.searchText) { _, _ in
            recomputeFilteredSections()
        }
        .onChange(of: displaySettings.sortOrder) { _, _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                recomputeFilteredSections()
            }
        }
        .onChange(of: displaySettings.sortAscending) { _, _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                recomputeFilteredSections()
            }
        }
        .onChange(of: store.selectedSubtopicId) { _, _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                recomputeFilteredSections()
            }
        }
        .onChange(of: store.selectedChannelId) { _, _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                recomputeFilteredSections()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func scrollContent(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(displayedSections) { section in
                    sectionView(section, proxy: proxy)
                }
            }
        }
        .coordinateSpace(name: "scroll")
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in viewportHeight = h }
            }
        }
        .onPreferenceChange(SectionProgressKey.self) { newValues in
            sectionProgressValues = newValues
            // Show progress bar while scrolling, fade out after pause
            if !isScrolling {
                withAnimation(.easeIn(duration: 0.15)) { isScrolling = true }
            }
            scrollFadeTask?.cancel()
            scrollFadeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.0))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.6)) { isScrolling = false }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: TopicSection, proxy: ScrollViewProxy) -> some View {
        let gridSpacing: CGFloat = displaySettings.showMetadata ? GridConstants.metadataGridSpacing : GridConstants.compactGridSpacing
        Section {
            LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                ForEach(section.videos) { video in
                    VideoCardWrapper(video: video, isSelected: selectedVideoId == video.id, cacheDir: thumbnailCache.cacheDirURL, displaySettings: displaySettings, store: store) {
                        selectVideo(video.id, proxy: proxy)
                    } onDoubleClick: {
                        openOnYouTube(video)
                    }
                    .id(video.id)
                    .contextMenu { videoContextMenu(for: video, topicId: section.topicId) }
                }
            }
            .padding(.horizontal, GridConstants.horizontalPadding)
            .padding(.bottom, GridConstants.sectionBottomPadding)
            .background {
                GeometryReader { geo in
                    let frame = geo.frame(in: .named("scroll"))
                    let scrolled = -frame.minY
                    let scrollableDistance = max(frame.height - viewportHeight, 1)
                    let progress = min(max(scrolled / scrollableDistance, 0), 1)
                    Color.clear
                        .preference(key: SectionProgressKey.self, value: [section.id: progress])
                }
            }
        } header: {
            VStack(spacing: 0) {
                if let creatorName = section.creatorName {
                    // Creator grouping mode: show creator header
                    CreatorSectionHeaderView(
                        channelName: creatorName,
                        channelIconUrl: section.channelIconUrl,
                        count: section.videos.count,
                        totalCount: section.totalCount,
                        topicNames: section.topicNames,
                        sectionId: section.id,
                        progress: sectionProgressValues[section.id] ?? 0,
                        highlightTerms: store.parsedQuery.includeTerms
                    )
                    .onTapGesture {
                        store.inspectedCreatorName = creatorName
                    }
                    .onHover { hovering in
                        if hovering {
                            store.inspectedCreatorName = creatorName
                        }
                    }
                } else {
                    // Normal topic mode: show topic header + creator circles
                    SectionHeaderView(
                        name: section.topicName,
                        count: section.videos.count,
                        totalCount: section.totalCount,
                        topicId: section.topicId,
                        progress: sectionProgressValues[section.id] ?? 0,
                        showProgress: isScrolling,
                        highlightTerms: store.parsedQuery.includeTerms
                    )
                    CreatorCirclesBar(
                        channels: store.channelsForTopic(section.topicId),
                        selectedChannelId: store.selectedChannelId,
                        topicId: section.topicId,
                        videoCountForChannel: { store.videoCountForChannel($0, inTopic: section.topicId) },
                        hasRecentContent: { store.channelHasRecentContent($0, inTopic: section.topicId) },
                        onSelect: { channelId in
                            // Set the inspector to show creator detail
                            let channel = store.channelsForTopic(section.topicId).first(where: { $0.channelId == channelId })
                            if store.selectedChannelId == channelId {
                                // Deselecting — clear creator inspection
                                store.inspectedCreatorName = nil
                            } else {
                                store.inspectedCreatorName = channel?.name
                            }
                            // Keep sidebar on this topic and focus the channel bar
                            suppressSidebarSync = true
                            channelBarFocused = (store.selectedChannelId != channelId) // will be selected
                            store.toggleChannelFilter(channelId)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                suppressSidebarSync = false
                            }
                        }
                    )
                }
            }
            .id("header-\(section.id)")
        }
    }

    // MARK: - Search Filtering (cached)

    private func recomputeFilteredSections() {
        let query = store.parsedQuery
        var result: [TopicSection]

        if query.isEmpty {
            result = sections
            store.searchResultCount = 0
        } else {
            result = []
            for section in sections {
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

        // Filter by selected subtopic if one is active
        if let subId = store.selectedSubtopicId {
            result = result.map { section in
                let filtered = section.videos.filter { section.videoSubtopicMap[$0.id] == subId }
                guard !filtered.isEmpty else { return section }
                return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: filtered, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap)
            }.filter { !$0.videos.isEmpty }
        }

        // Filter by selected channel if one is active
        if let channelId = store.selectedChannelId {
            result = result.map { section in
                let filtered = section.videos.filter { $0.channelId == channelId }
                guard !filtered.isEmpty else { return section }
                return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: filtered, totalCount: section.videos.count, videoSubtopicMap: section.videoSubtopicMap)
            }.filter { !$0.videos.isEmpty }
        }

        // Apply sort to videos within each section (nil = playlist order)
        if let sortOrder = displaySettings.sortOrder {
            let ascending = displaySettings.sortAscending
            if sortOrder == .creator {
                // Group by creator: explode each topic section into per-creator sub-sections
                cachedFilteredSections = result.flatMap { section in
                    GridSectionLogic.groupByCreator(
                        section: section,
                        ascending: ascending,
                        channelCounts: store.channelCounts,
                        includeTopicMarker: false
                    )
                }
            } else {
                cachedFilteredSections = result.map { section in
                    let sorted = GridSectionLogic.sortVideos(section.videos, by: sortOrder, ascending: ascending)
                    return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: sorted, totalCount: section.totalCount, videoSubtopicMap: section.videoSubtopicMap)
                }
            }
        } else {
            cachedFilteredSections = result
        }
    }

    // MARK: - Data Loading

    private func loadSections() {
        var newSections: [TopicSection] = []
        var flatIds: [String] = []

        for topic in store.topics {
            if topic.subtopics.isEmpty {
                let videos = mapVideos(store.videosForTopic(topic.id))
                if !videos.isEmpty {
                    newSections.append(TopicSection(topicId: topic.id, topicName: topic.name, videos: videos))
                    flatIds.append(contentsOf: videos.map(\.id))
                }
            } else {
                // Merge all subtopic videos into one section under the parent topic
                var allVideos: [VideoGridItemModel] = []
                var subtopicMap: [String: Int64] = [:]

                for sub in topic.subtopics {
                    let videos = mapVideos(store.videosForTopic(sub.id))
                    for v in videos { subtopicMap[v.id] = sub.id }
                    allVideos.append(contentsOf: videos)
                }
                // Include any videos directly on the parent
                let parentVideos = mapVideos(store.videosForTopic(topic.id))
                allVideos.append(contentsOf: parentVideos)

                if !allVideos.isEmpty {
                    newSections.append(TopicSection(topicId: topic.id, topicName: topic.name, videos: allVideos, videoSubtopicMap: subtopicMap))
                    flatIds.append(contentsOf: allVideos.map(\.id))
                }
            }
        }

        sections = newSections
        allVideoIds = flatIds
    }

    private func mapVideos(_ viewModels: [VideoViewModel]) -> [VideoGridItemModel] {
        viewModels.map { v in
            VideoGridItemModel(
                id: v.videoId,
                title: v.title,
                channelName: v.channelName,
                thumbnailUrl: v.thumbnailUrl,
                viewCount: v.viewCount,
                publishedAt: v.publishedAt,
                duration: v.duration,
                channelIconUrl: v.channelIconUrl.flatMap { URL(string: $0) },
                channelId: v.channelId,
                isPlaceholder: false,
                placeholderMessage: nil
            )
        }
    }

    // MARK: - Navigation

    private func navigateChannel(by offset: Int) {
        guard let currentId = store.selectedChannelId,
              let topicId = store.selectedTopicId else { return }
        let channels = store.channelsForTopic(topicId)
        guard let currentIndex = channels.firstIndex(where: { $0.channelId == currentId }) else { return }
        let newIndex = max(0, min(channels.count - 1, currentIndex + offset))
        let newChannel = channels[newIndex]
        suppressSidebarSync = true
        channelBarFocused = true
        store.selectedChannelId = newChannel.channelId
        store.inspectedCreatorName = newChannel.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            suppressSidebarSync = false
        }
    }

    /// Move focus from channel bar into the video grid, selecting the first video.
    private func enterVideoGrid(proxy: ScrollViewProxy) {
        channelBarFocused = false
        if let firstId = displayedVideoIds.first {
            selectedVideoId = firstId
            proxy.scrollTo(firstId, anchor: .center)
        }
    }

    /// If a channel filter is active and the selected video is in the top row, move focus to the channel bar.
    /// Returns true if focus moved to channel bar.
    private func tryEnterChannelBar(proxy: ScrollViewProxy) -> Bool {
        guard store.selectedChannelId != nil, !channelBarFocused else { return false }
        let ids = displayedVideoIds
        guard let currentId = selectedVideoId,
              let currentIndex = ids.firstIndex(of: currentId) else { return false }
        // If in the top row (index < column count), move to channel bar
        if currentIndex < estimatedColumnCount {
            channelBarFocused = true
            return true
        }
        return false
    }

    private func selectVideo(_ id: String, proxy: ScrollViewProxy) {
        selectedVideoId = id
        store.inspectedCreatorName = nil
        channelBarFocused = false
        isFocused = true
    }

    private func syncSidebarToVideo(_ videoId: String?) {
        guard !suppressSidebarSync else { return }
        // Don't change topic when a channel filter is active — it would clear the filter
        guard store.selectedChannelId == nil else { return }
        guard let vid = videoId,
              let section = sections.first(where: { $0.videos.contains(where: { $0.id == vid }) }) else { return }
        if store.selectedSubtopicId == nil {
            store.selectedTopicId = section.topicId
        }
    }

    private func scrollToTopic(_ topicId: Int64?, proxy: ScrollViewProxy) {
        guard let topicId else { return }
        // Clear channel filter when navigating to a different topic
        if store.selectedChannelId != nil {
            store.inspectedCreatorName = nil
            store.clearChannelFilter()
        }
        suppressSidebarSync = true
        // Scroll to first video with .top anchor — this positions the pinned header
        // at the top of the viewport with content immediately below it
        if let section = displayedSections.first(where: { $0.topicId == topicId }),
           let firstVideo = section.videos.first {
            proxy.scrollTo(firstVideo.id, anchor: .top)
            selectedVideoId = firstVideo.id
        } else {
            proxy.scrollTo("header-topic-\(topicId)", anchor: .top)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            suppressSidebarSync = false
        }
    }

    private func navigate(by offset: Int, proxy: ScrollViewProxy) {
        let ids = displayedVideoIds
        guard !ids.isEmpty else { return }
        let currentIndex = selectedVideoId.flatMap { ids.firstIndex(of: $0) } ?? 0
        let newIndex = max(0, min(ids.count - 1, currentIndex + offset))
        let newId = ids[newIndex]
        selectedVideoId = newId
        proxy.scrollTo(newId, anchor: .center)
    }

    private func jumpToEdge(first: Bool, proxy: ScrollViewProxy) {
        let ids = displayedVideoIds
        guard !ids.isEmpty else { return }
        let id = first ? ids.first! : ids.last!
        selectedVideoId = id
        withAnimation {
            proxy.scrollTo(id, anchor: first ? .top : .bottom)
        }
    }

    private func openOnYouTube(_ video: VideoGridItemModel) {
        if let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func videoContextMenu(for video: VideoGridItemModel, topicId: Int64) -> some View {
        let otherTopics = store.topics.filter { $0.id != topicId }
        Menu("Move to…") {
            ForEach(otherTopics) { other in
                Button(other.name) {
                    store.moveVideo(videoId: video.id, toTopicId: other.id)
                }
            }
        }
    }
}

// MARK: - Models

struct TopicSection: Identifiable {
    let topicId: Int64
    let topicName: String
    let videos: [VideoGridItemModel]
    var totalCount: Int?
    var headerCountOverride: Int? = nil
    var videoSubtopicMap: [String: Int64] = [:]
    var displayMode: TopicDisplayMode = .saved
    // Creator-mode fields
    var creatorName: String? = nil
    var channelIconUrl: URL? = nil
    var topicNames: [String] = []

    var id: String {
        if let creator = creatorName {
            return "creator-\(topicId)-\(creator)"
        }
        return "topic-\(topicId)"
    }
}

struct VideoGridItemModel: Identifiable, Equatable {
    let id: String
    let title: String
    let channelName: String?
    let thumbnailUrl: URL?
    let viewCount: String?
    let publishedAt: String?
    let duration: String?
    let channelIconUrl: URL?
    let channelId: String?
    let isPlaceholder: Bool
    let placeholderMessage: String?
}

// MARK: - Preference Keys

private struct ContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 800
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct SectionProgressKey: PreferenceKey {
    static let defaultValue: [String: Double] = [:]
    static func reduce(value: inout [String: Double], nextValue: () -> [String: Double]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - View Extensions

extension View {
    func onDoubleClick(perform action: @escaping () -> Void) -> some View {
        modifier(DoubleClickModifier(action: action))
    }

    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

private struct DoubleClickModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.overlay { DoubleClickView(action: action) }
    }
}

private struct DoubleClickView: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView {
        let view = DoubleClickNSView()
        view.action = action
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DoubleClickNSView)?.action = action
    }
}

private class DoubleClickNSView: NSView {
    var action: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            action?()
        } else {
            nextResponder?.mouseDown(with: event)
        }
    }
}
