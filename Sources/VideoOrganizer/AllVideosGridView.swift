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
                .onKeyPress(.rightArrow) { navigate(by: 1, proxy: proxy); return .handled }
                .onKeyPress(.leftArrow) { navigate(by: -1, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "l")) { _ in navigate(by: 1, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "h")) { _ in navigate(by: -1, proxy: proxy); return .handled }
                .onKeyPress(.downArrow) { navigate(by: estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(.upArrow) { navigate(by: -estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "j")) { _ in navigate(by: estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "k")) { _ in navigate(by: -estimatedColumnCount, proxy: proxy); return .handled }
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
        .onPreferenceChange(SectionProgressKey.self) { sectionProgressValues = $0 }
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
            SectionHeaderView(
                name: section.topicName,
                count: section.videos.count,
                totalCount: section.totalCount,
                topicId: section.topicId,
                progress: sectionProgressValues[section.id] ?? 0,
                highlightTerms: store.parsedQuery.includeTerms
            )
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

        // Apply sort to videos within each section (nil = playlist order)
        if let sortOrder = displaySettings.sortOrder {
            let ascending = displaySettings.sortAscending
            cachedFilteredSections = result.map { section in
                let sorted = sortVideos(section.videos, by: sortOrder, ascending: ascending)
                return TopicSection(topicId: section.topicId, topicName: section.topicName, videos: sorted, totalCount: section.totalCount, videoSubtopicMap: section.videoSubtopicMap)
            }
        } else {
            cachedFilteredSections = result
        }
    }

    private func sortVideos(_ videos: [VideoGridItemModel], by order: SortOrder, ascending: Bool) -> [VideoGridItemModel] {
        if order == .shuffle { return videos.shuffled() }
        return videos.sorted { a, b in
            let result: Bool
            switch order {
            case .views:
                result = parseViewCount(a.viewCount) > parseViewCount(b.viewCount)
            case .date:
                result = parseAge(a.publishedAt) < parseAge(b.publishedAt)
            case .duration:
                result = parseDuration(a.duration) > parseDuration(b.duration)
            case .creator:
                let aName = a.channelName ?? ""
                let bName = b.channelName ?? ""
                if aName == bName {
                    // Within same creator, sort by date (newest first)
                    result = parseAge(a.publishedAt) < parseAge(b.publishedAt)
                } else {
                    result = aName.localizedStandardCompare(bName) == .orderedAscending
                }
            case .alphabetical:
                result = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .shuffle:
                result = false
            }
            return ascending ? !result : result
        }
    }

    private func parseViewCount(_ str: String?) -> Int {
        guard let str else { return 0 }
        let cleaned = str.replacingOccurrences(of: " views", with: "")
        if cleaned.hasSuffix("M") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000_000)
        } else if cleaned.hasSuffix("K") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000)
        }
        return Int(cleaned) ?? 0
    }

    private func parseAge(_ str: String?) -> Int {
        // Returns approximate days ago for sorting. Lower = newer.
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
        // Parses "1:23", "12:34", "1:02:34" into total seconds
        guard let str else { return 0 }
        let parts = str.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
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
                channelIconUrl: v.channelIconUrl.flatMap { URL(string: $0) }
            )
        }
    }

    // MARK: - Navigation

    private func selectVideo(_ id: String, proxy: ScrollViewProxy) {
        selectedVideoId = id
        isFocused = true
    }

    private func syncSidebarToVideo(_ videoId: String?) {
        guard !suppressSidebarSync else { return }
        guard let vid = videoId,
              let section = sections.first(where: { $0.videos.contains(where: { $0.id == vid }) }) else { return }
        if store.selectedSubtopicId == nil {
            store.selectedTopicId = section.topicId
        }
    }

    private func scrollToTopic(_ topicId: Int64?, proxy: ScrollViewProxy) {
        guard let topicId else { return }
        suppressSidebarSync = true
        proxy.scrollTo("header-topic-\(topicId)", anchor: .top)
        if let section = displayedSections.first(where: { $0.topicId == topicId }),
           let firstVideo = section.videos.first {
            selectedVideoId = firstVideo.id
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
    var videoSubtopicMap: [String: Int64] = [:]
    // Creator-mode fields
    var creatorName: String? = nil
    var channelIconUrl: URL? = nil
    var topicNames: [String] = []

    var id: String {
        if let creator = creatorName {
            return "creator-\(creator)"
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
