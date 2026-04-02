import SwiftUI

struct AllVideosGridView: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache
    @Bindable var displaySettings: DisplaySettings
    @State private var sections: [TopicSection] = []
    @State private var allVideoIds: [String] = [] // Flat list for keyboard navigation
    private var selectedVideoId: String? {
        get { store.selectedVideoId }
        nonmutating set { store.selectedVideoId = newValue }
    }
    @State private var containerWidth: CGFloat = 800
    @State private var sectionProgressValues: [Int64: Double] = [:]
    @State private var viewportHeight: CGFloat = 600
    @FocusState private var isFocused: Bool

    private var gridColumns: [GridItem] {
        let min = displaySettings.thumbnailSize
        let max = displaySettings.thumbnailSize + 60
        let spacing: CGFloat = displaySettings.showMetadata ? 16 : 4
        return [GridItem(.adaptive(minimum: min, maximum: max), spacing: spacing)]
    }

    /// Estimated number of columns based on container width and thumbnail size
    private var estimatedColumnCount: Int {
        let colWidth = displaySettings.thumbnailSize + 16 // size + spacing
        let usableWidth = containerWidth - 40 // minus horizontal padding
        return max(1, Int(usableWidth / colWidth))
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
                .focused($isFocused)
                // Left/Right: move one item, wrapping rows
                .onKeyPress(.rightArrow) { navigate(by: 1, proxy: proxy); return .handled }
                .onKeyPress(.leftArrow) { navigate(by: -1, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "l")) { _ in navigate(by: 1, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "h")) { _ in navigate(by: -1, proxy: proxy); return .handled }
                // Up/Down: move one row (jump by column count)
                .onKeyPress(.downArrow) { navigate(by: estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(.upArrow) { navigate(by: -estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "j")) { _ in navigate(by: estimatedColumnCount, proxy: proxy); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "k")) { _ in navigate(by: -estimatedColumnCount, proxy: proxy); return .handled }
                // Page up/down: jump several rows
                .onKeyPress(.pageDown) { navigate(by: estimatedColumnCount * 4, proxy: proxy); return .handled }
                .onKeyPress(.pageUp) { navigate(by: -estimatedColumnCount * 4, proxy: proxy); return .handled }
                // Home/End
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
            isFocused = true
            if selectedVideoId == nil, let first = allVideoIds.first {
                selectedVideoId = first
            }
        }
        .onChange(of: store.topics) { _, _ in
            loadSections()
        }
        .onChange(of: store.searchText) { _, _ in
            store.searchResultCount = filteredSections.reduce(0) { $0 + $1.videos.count }
        }
    }

    @ViewBuilder
    private func scrollContent(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(filteredSections) { section in
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
        Section {
            LazyVGrid(columns: gridColumns, spacing: displaySettings.showMetadata ? 16 : 4) {
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
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .background {
                GeometryReader { geo in
                    let frame = geo.frame(in: .named("scroll"))
                    let scrolled = -frame.minY
                    let scrollableDistance = max(frame.height - viewportHeight, 1)
                    let progress = min(max(scrolled / scrollableDistance, 0), 1)
                    Color.clear
                        .preference(key: SectionProgressKey.self, value: [section.topicId: progress])
                }
            }
        } header: {
            SectionHeaderView(
                name: section.topicName,
                count: section.videos.count,
                totalCount: section.totalCount,
                topicId: section.topicId,
                progress: sectionProgressValues[section.topicId] ?? 0,
                highlightTerms: store.parsedQuery.includeTerms
            )
            .id("header-\(section.topicId)")
        }
    }

    private func syncSidebarToVideo(_ videoId: String?) {
        if let vid = videoId, let section = sections.first(where: { $0.videos.contains(where: { $0.id == vid }) }) {
            store.selectedTopicId = section.topicId
        }
    }

    private func scrollToTopic(_ topicId: Int64?, proxy: ScrollViewProxy) {
        guard let topicId else { return }
        withAnimation {
            proxy.scrollTo("header-\(topicId)", anchor: .top)
        }
        if let section = sections.first(where: { $0.topicId == topicId }),
           let firstVideo = section.videos.first {
            selectedVideoId = firstVideo.id
        }
    }

    // MARK: - Search Filtering

    private var filteredSections: [TopicSection] {
        let query = store.parsedQuery
        guard !query.isEmpty else { return sections }

        var result: [TopicSection] = []
        for section in sections {
            if query.matches(fields: [section.topicName]) {
                result.append(TopicSection(topicId: section.topicId, topicName: section.topicName, videos: section.videos, totalCount: section.videos.count))
            } else {
                let matching = section.videos.filter { video in
                    query.matches(fields: [video.title, video.channelName ?? "", section.topicName])
                }
                if !matching.isEmpty {
                    result.append(TopicSection(topicId: section.topicId, topicName: section.topicName, videos: matching, totalCount: section.videos.count))
                }
            }
        }
        return result
    }

    private var filteredVideoIds: [String] {
        filteredSections.flatMap { $0.videos.map(\.id) }
    }

    // MARK: - Data Loading

    private func loadSections() {
        var newSections: [TopicSection] = []
        var flatIds: [String] = []

        for topic in store.topics {
            let videos = store.videosForTopic(topic.id).map { v in
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
            if !videos.isEmpty {
                newSections.append(TopicSection(topicId: topic.id, topicName: topic.name, videos: videos))
                flatIds.append(contentsOf: videos.map(\.id))
            }
        }

        sections = newSections
        allVideoIds = flatIds
    }

    // MARK: - Navigation

    private func selectVideo(_ id: String, proxy: ScrollViewProxy) {
        selectedVideoId = id
        isFocused = true
    }

    private func navigate(by offset: Int, proxy: ScrollViewProxy) {
        let ids = filteredVideoIds
        guard !ids.isEmpty else { return }
        let currentIndex = selectedVideoId.flatMap { ids.firstIndex(of: $0) } ?? 0
        let newIndex = max(0, min(ids.count - 1, currentIndex + offset))
        let newId = ids[newIndex]
        selectedVideoId = newId
        withAnimation {
            proxy.scrollTo(newId, anchor: .center)
        }
    }

    private func jumpToEdge(first: Bool, proxy: ScrollViewProxy) {
        let ids = filteredVideoIds
        guard !ids.isEmpty else { return }
        let id = first ? ids.first! : ids.last!
        selectedVideoId = id
        withAnimation {
            proxy.scrollTo(id, anchor: first ? .top : .bottom)
        }
    }

    private func openOnYouTube(_ video: VideoGridItemModel) {
        let urlString = "https://www.youtube.com/watch?v=\(video.id)"
        if let url = URL(string: urlString) {
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

// MARK: - Section Header

private struct SectionHeaderView: View {
    let name: String
    let count: Int
    var totalCount: Int?
    let topicId: Int64
    let progress: Double
    var highlightTerms: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HighlightedText(name, terms: highlightTerms)
                    .font(.title3.bold())

                Group {
                    if let total = totalCount {
                        Text("\(count) of \(total)")
                    } else {
                        Text("\(count)")
                    }
                }
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            // Section progress bar
            ZStack(alignment: .leading) {
                // Track (always visible)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.1))

                // Fill
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * max(progress, 0))
                        .animation(.easeOut(duration: 0.15), value: progress)
                }
            }
            .frame(height: 3)
        }
        .background(.bar)
    }
}

// MARK: - Card Wrapper (owns hover state above the NSView overlay)

private struct VideoCardWrapper: View {
    let video: VideoGridItemModel
    let isSelected: Bool
    let cacheDir: URL
    let displaySettings: DisplaySettings
    let store: OrganizerStore
    let onTap: () -> Void
    let onDoubleClick: () -> Void

    @State private var isHovering = false
    @State private var hoverOffTask: Task<Void, Never>?

    var body: some View {
        VideoGridItem(video: video, isSelected: isSelected, isHovering: isHovering, cacheDir: cacheDir, showMetadata: displaySettings.showMetadata, size: displaySettings.thumbnailSize, highlightTerms: store.parsedQuery.includeTerms, forceShowTitle: !store.parsedQuery.isEmpty)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { onDoubleClick() }
            )
            .simultaneousGesture(
                TapGesture(count: 1).onEnded { onTap() }
            )
            .onHover { hovering in
            if hovering {
                hoverOffTask?.cancel()
                hoverOffTask = nil
                isHovering = true
                store.hoveredVideoId = video.id
            } else {
                hoverOffTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        isHovering = false
                    }
                    if store.hoveredVideoId == video.id {
                        store.hoveredVideoId = nil
                    }
                }
            }
        }
        .cursor(.pointingHand)
    }
}

// MARK: - Grid Item

struct VideoGridItem: View {
    let video: VideoGridItemModel
    let isSelected: Bool
    let isHovering: Bool
    let cacheDir: URL
    let showMetadata: Bool
    let size: Double
    var highlightTerms: [String] = []
    var forceShowTitle: Bool = false

    private var cachedImage: NSImage? {
        let path = cacheDir.appendingPathComponent("\(video.id).jpg")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return NSImage(contentsOf: path)
    }

    private var titleFont: Font {
        if size < 160 { return .system(size: 9, weight: .medium) }
        if size < 220 { return .caption.weight(.medium) }
        if size < 300 { return .subheadline.weight(.medium) }
        return .body.weight(.medium)
    }

    private var channelFont: Font {
        if size < 160 { return .system(size: 8) }
        if size < 220 { return .caption2 }
        if size < 300 { return .caption }
        return .subheadline
    }

    private var cornerRadius: CGFloat {
        if size < 160 { return 8 }
        if size < 300 { return 10 }
        return 12
    }

    private var metadataFont: Font {
        if size < 160 { return .system(size: 8) }
        if size < 220 { return .caption2 }
        if size < 300 { return .caption }
        return .subheadline
    }

    private var metadataLine: String? {
        var parts: [String] = []
        if let views = video.viewCount {
            parts.append(views)
        }
        if let date = video.publishedAt {
            parts.append(date)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var channelIconSize: CGFloat {
        if size < 160 { return 16 }
        if size < 220 { return 22 }
        if size < 300 { return 28 }
        return 32
    }

    private var cardPadding: CGFloat {
        if size < 160 { return 6 }
        if size < 220 { return 8 }
        return 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: showMetadata ? (size < 200 ? 4 : 8) : 0) {
            // Thumbnail with duration badge and compact hover overlay
            ZStack(alignment: .bottomTrailing) {
                thumbnailView
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .scaleEffect(isHovering ? 1.01 : 1.0)
                if let duration = video.duration {
                    Text(duration)
                        .font(.system(size: size < 200 ? 8 : 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                        .padding(size < 200 ? 3 : 5)
                }
            }

            if showMetadata {
                // YouTube-style: channel icon left, text block right
                HStack(alignment: .top, spacing: size < 200 ? 6 : 10) {
                    channelIconView
                        .frame(width: channelIconSize, height: channelIconSize)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        HighlightedText(video.title, terms: highlightTerms)
                            .font(titleFont)
                            .lineLimit(2)

                        if let channel = video.channelName {
                            HighlightedText(channel, terms: highlightTerms)
                                .font(channelFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let meta = metadataLine {
                            Text(meta)
                                .font(metadataFont)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            } else if forceShowTitle {
                // Compact mode during search: show title so user sees why it matched
                HighlightedText(video.title, terms: highlightTerms)
                    .font(titleFont)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(showMetadata ? cardPadding : 2)
        .background(
            RoundedRectangle(cornerRadius: showMetadata ? cornerRadius + 6 : cornerRadius + 2, style: .continuous)
                .fill(Color.white.opacity(isHovering || isSelected ? 0.08 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: showMetadata ? cornerRadius + 6 : cornerRadius + 2, style: .continuous)
                .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        )
        .help(video.title)
    }

    @ViewBuilder
    private var channelIconView: some View {
        if let iconUrl = video.channelIconUrl {
            AsyncImage(url: iconUrl) { phase in
                if case .success(let image) = phase {
                    image.resizable()
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Image(systemName: "person.circle.fill")
                .resizable()
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let nsImage = cachedImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
        } else {
            AsyncImage(url: video.thumbnailUrl) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                case .failure:
                    placeholder
                default:
                    placeholder
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private var placeholder: some View {
        Color(nsColor: .quaternaryLabelColor)
            .aspectRatio(16/9, contentMode: .fit)
            .overlay {
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

// MARK: - Models

struct TopicSection: Identifiable {
    let topicId: Int64
    let topicName: String
    let videos: [VideoGridItemModel]
    var totalCount: Int? // non-nil during search = original count
    var id: Int64 { topicId }
}

private struct ContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 800
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct SectionProgressKey: PreferenceKey {
    static let defaultValue: [Int64: Double] = [:]
    static func reduce(value: inout [Int64: Double], nextValue: () -> [Int64: Double]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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

// MARK: - Double Click Modifier

private struct DoubleClickModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            DoubleClickView(action: action)
        }
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
    var singleClickAction: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            action?()
        } else {
            // Let the next responder (SwiftUI Button) handle single clicks
            nextResponder?.mouseDown(with: event)
        }
    }
}

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
