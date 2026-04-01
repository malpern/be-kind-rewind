import SwiftUI

struct AllVideosGridView: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache
    @Bindable var displaySettings: DisplaySettings
    @State private var sections: [TopicSection] = []
    @State private var allVideoIds: [String] = [] // Flat list for keyboard navigation
    @State private var selectedVideoId: String?
    @State private var containerWidth: CGFloat = 800
    @FocusState private var isFocused: Bool

    private var gridColumns: [GridItem] {
        let min = displaySettings.thumbnailSize
        let max = displaySettings.thumbnailSize + 60
        return [GridItem(.adaptive(minimum: min, maximum: max), spacing: 16)]
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
    }

    @ViewBuilder
    private func scrollContent(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    sectionView(section, proxy: proxy)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: TopicSection, proxy: ScrollViewProxy) -> some View {
        Section {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(section.videos) { video in
                    Button { selectVideo(video.id, proxy: proxy) } label: {
                        VideoGridItem(video: video, isSelected: selectedVideoId == video.id, cacheDir: thumbnailCache.cacheDirURL, showChannel: displaySettings.showChannelName, showChannelIcon: displaySettings.showChannelIcon, size: displaySettings.thumbnailSize)
                    }
                    .buttonStyle(.plain)
                    .onDoubleClick { openOnYouTube(video) }
                    .id(video.id)
                    .contextMenu { videoContextMenu(for: video, topicId: section.topicId) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        } header: {
            SectionHeaderView(
                name: section.topicName,
                count: section.videos.count,
                topicId: section.topicId,
                progress: sectionProgress(for: section)
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
                    thumbnailUrl: v.thumbnailUrl
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
        guard !allVideoIds.isEmpty else { return }
        let currentIndex = selectedVideoId.flatMap { allVideoIds.firstIndex(of: $0) } ?? 0
        let newIndex = max(0, min(allVideoIds.count - 1, currentIndex + offset))
        let newId = allVideoIds[newIndex]
        selectedVideoId = newId
        withAnimation {
            proxy.scrollTo(newId, anchor: .center)
        }
    }

    private func jumpToEdge(first: Bool, proxy: ScrollViewProxy) {
        guard !allVideoIds.isEmpty else { return }
        let id = first ? allVideoIds.first! : allVideoIds.last!
        selectedVideoId = id
        withAnimation {
            proxy.scrollTo(id, anchor: first ? .top : .bottom)
        }
    }

    private func sectionProgress(for section: TopicSection) -> Double {
        guard let selectedId = selectedVideoId,
              let index = section.videos.firstIndex(where: { $0.id == selectedId }),
              section.videos.count > 1 else {
            // If selection is in this section but no match, check if it's the active section
            if store.selectedTopicId == section.topicId {
                return 0
            }
            return 0
        }
        return Double(index + 1) / Double(section.videos.count)
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
    let topicId: Int64
    let progress: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.title3.bold())

                Text("\(count)")
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

// MARK: - Grid Item

struct VideoGridItem: View {
    let video: VideoGridItemModel
    let isSelected: Bool
    let cacheDir: URL
    let showChannel: Bool
    let showChannelIcon: Bool
    let size: Double

    @State private var isHovering = false

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

    private var titleHeight: CGFloat {
        if size < 160 { return 22 }
        if size < 220 { return 32 }
        if size < 300 { return 38 }
        return 44
    }

    private var cornerRadius: CGFloat {
        if size < 160 { return 4 }
        if size < 300 { return 6 }
        return 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size < 200 ? 3 : 6) {
            thumbnailView
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: cornerRadius))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Color.accentColor, lineWidth: size < 200 ? 2 : 3)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Color.primary.opacity(0.3), lineWidth: 1.5)
                    }
                }
                .shadow(color: isHovering ? .black.opacity(0.15) : .clear, radius: 4, y: 2)
                .scaleEffect(isHovering ? 1.02 : 1.0)

            Text(video.title)
                .font(titleFont)
                .lineLimit(2)
                .frame(height: titleHeight, alignment: .top)

            if showChannel, let channel = video.channelName {
                HStack(spacing: 3) {
                    if showChannelIcon {
                        Image(systemName: "person.circle.fill")
                            .font(channelFont)
                            .foregroundStyle(.tertiary)
                    }
                    Text(channel)
                        .font(channelFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .cursor(.pointingHand)
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
    var id: Int64 { topicId }
}

private struct ContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 800
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct VideoGridItemModel: Identifiable, Equatable {
    let id: String
    let title: String
    let channelName: String?
    let thumbnailUrl: URL?
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

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            action?()
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
