import SwiftUI

struct TopicSidebar: View {
    @Bindable var store: OrganizerStore
    @Bindable var displaySettings: DisplaySettings
    @Environment(\.openSettings) private var openSettings
    @State private var showingSettings = false
    @State private var expandedTopicId: Int64? = nil
    @State private var selectedCreatorSectionId: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var isCreatorMode: Bool {
        displaySettings.sortOrder == .creator
    }

    private var isWatchMode: Bool {
        store.pageDisplayMode == .watchCandidates
    }

    private var filteredTopics: [TopicViewModel] {
        let query = store.parsedQuery
        guard !query.isEmpty else { return store.topics }
        return store.topics.filter { topic in
            if query.matches(fields: [topic.name]) { return true }
            let videos = store.videosForTopic(topic.id)
            return videos.contains { v in
                query.matches(fields: [v.title, v.channelName ?? "", topic.name])
            }
        }
    }

    private func isSelected(_ topic: TopicViewModel) -> Bool {
        if isWatchMode {
            return store.selectedTopicId == topic.id
        }
        if let selectedSubtopicId = store.selectedSubtopicId {
            return selectedSubtopicId == topic.id
        }
        return store.selectedTopicId == topic.id
    }

    private func isViewportTopic(_ topic: TopicViewModel) -> Bool {
        store.viewportTopicId == topic.id
    }

    private func isExpanded(_ topic: TopicViewModel) -> Bool {
        expandedTopicId == topic.id || store.viewportTopicId == topic.id
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 4) {
                        HStack(spacing: 0) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.tertiary)
                                .font(.body)
                                .frame(width: 24)
                            TextField("", text: $store.searchText, prompt: Text("Search").foregroundStyle(.tertiary))
                                .textFieldStyle(.plain)
                                .font(.body)
                                .focused($searchFocused)
                                .onSubmit {
                                    if let first = store.typeaheadSuggestions().first {
                                        selectSuggestion(first)
                                    }
                                }
                            if !store.searchText.isEmpty {
                                Button {
                                    store.searchText = ""
                                    searchFocused = true
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                        .font(.body)
                                }
                                .buttonStyle(.plain)
                                .help("Clear search")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))

                        let suggestions = store.typeaheadSuggestions()
                        if searchFocused && !suggestions.isEmpty {
                            SearchTypeahead(suggestions: suggestions, searchText: store.searchText) { suggestion in
                                selectSuggestion(suggestion)
                            }
                        }
                    }
                    .id("search-field")

                    HStack {
                        Text("\(filteredTopics.count) Topics")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if store.parsedQuery.isEmpty {
                            Text("\(store.totalVideoCount) videos")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("\(store.searchResultCount) results")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 6)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredTopics) { topic in
                            TopicRow(
                                topic: topic,
                                count: displayedCount(for: topic),
                                highlightTerms: store.parsedQuery.includeTerms,
                                isSelected: isSelected(topic),
                                isViewport: isViewportTopic(topic)
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if expandedTopicId == topic.id {
                                            expandedTopicId = nil
                                        } else {
                                            expandedTopicId = topic.id
                                        }
                                    }
                                }
                            )
                            .simultaneousGesture(
                                TapGesture(count: 1).onEnded {
                                    applySidebarSelection(topicId: topic.id, subtopicId: nil)
                                }
                            )
                            .accessibilityIdentifier("topic-\(topic.id)")
                            .accessibilityLabel("\(topic.name), \(displayedCount(for: topic)) videos")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {
                                applySidebarSelection(topicId: topic.id, subtopicId: nil)
                            }
                            .contextMenu { contextMenu(for: topic) }
                            .id(topic.id)

                            if isExpanded(topic) {
                                if isCreatorMode {
                                    ForEach(creatorEntries(for: topic)) { creator in
                                        Button {
                                            applyCreatorSelection(creator)
                                        } label: {
                                            CreatorSidebarRow(
                                                creator: creator,
                                                highlightTerms: store.parsedQuery.includeTerms,
                                                isSelected: selectedCreatorSectionId == creator.sectionId,
                                                isViewport: store.viewportCreatorSectionId == creator.sectionId
                                            )
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                        .contentShape(Rectangle())
                                        .contextMenu {
                                            if let url = creator.channelUrl {
                                                Button("Open Channel on YouTube") {
                                                    NSWorkspace.shared.open(url)
                                                }
                                            } else {
                                                Button("Open Channel on YouTube") {
                                                    let url = URL(string: "https://www.youtube.com/channel/\(creator.channelId)")!
                                                    NSWorkspace.shared.open(url)
                                                }
                                            }
                                        }
                                        .accessibilityIdentifier("creator-\(creator.sectionId)")
                                        .accessibilityLabel("\(creator.creatorName), \(creator.count) videos")
                                        .padding(.leading, 20)
                                        .id(creator.sectionId)
                                    }
                                } else if !isWatchMode && !topic.subtopics.isEmpty {
                                    ForEach(topic.subtopics) { sub in
                                        TopicRow(
                                            topic: sub,
                                            count: displayedCount(forSubtopic: sub, parentTopicId: topic.id),
                                            highlightTerms: store.parsedQuery.includeTerms,
                                            isSubtopic: true,
                                            isSelected: isSelected(sub),
                                            isViewport: store.viewportSubtopicId == sub.id
                                        )
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .simultaneousGesture(
                                            TapGesture(count: 1).onEnded {
                                                applySidebarSelection(topicId: topic.id, subtopicId: sub.id)
                                            }
                                        )
                                        .accessibilityIdentifier("topic-\(sub.id)")
                                        .accessibilityLabel("\(sub.name), \(displayedCount(forSubtopic: sub, parentTopicId: topic.id)) videos")
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityAction {
                                            applySidebarSelection(topicId: topic.id, subtopicId: sub.id)
                                        }
                                        .padding(.leading, 20)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                    }
                                }
                            }
                        }
                    }

                    if store.unassignedCount > 0 && store.parsedQuery.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "questionmark.folder")
                                .font(.title3)
                                .foregroundStyle(.orange)
                                .frame(width: 24)
                            Text("Unassigned")
                            Spacer()
                            Text("\(store.unassignedCount)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .focusable()
            .focused($listFocused)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    scrollProxy.scrollTo(filteredTopics.first?.id, anchor: .top)
                }
            }
            .onChange(of: displaySettings.sortOrder) { _, _ in
                if !isCreatorMode {
                    selectedCreatorSectionId = nil
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    scrollProxy.scrollTo(filteredTopics.first?.id, anchor: .top)
                }
            }
            .onChange(of: store.viewportTopicId) { _, topicId in
                guard let topicId else { return }
                if expandedTopicId != topicId {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedTopicId = topicId
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if isWatchMode {
                        scrollProxy.scrollTo(topicId, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            scrollProxy.scrollTo(topicId, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: store.viewportCreatorSectionId) { _, creatorSectionId in
                guard isCreatorMode, let creatorSectionId else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if isWatchMode {
                        scrollProxy.scrollTo(creatorSectionId, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            scrollProxy.scrollTo(creatorSectionId, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: store.viewportSubtopicId) { _, subtopicId in
                guard !isWatchMode, !isCreatorMode, let subtopicId else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        scrollProxy.scrollTo(subtopicId, anchor: .center)
                    }
                }
            }
            .onChange(of: displaySettings.focusSidebarRequested) { _, requested in
                guard requested else { return }
                displaySettings.focusSidebarRequested = false
                listFocused = true
            }
            .onChange(of: displaySettings.searchRequested) { _, requested in
                guard requested else { return }
                displaySettings.searchRequested = false
                withAnimation {
                    scrollProxy.scrollTo("search-field", anchor: .top)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    searchFocused = true
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        withAnimation {
                            scrollProxy.scrollTo("search-field", anchor: .top)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            searchFocused = true
                        }
                        displaySettings.toast.show("Search", icon: "magnifyingglass")
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Show search field")
                    .accessibilityIdentifier("showSearch")
                    .accessibilityLabel("Show search field")
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSettings.toggle()
                        displaySettings.toast.show("View Options", icon: "gearshape")
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("View options")
                    .accessibilityIdentifier("viewOptions")
                    .accessibilityLabel("View options")
                    .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                        DisplayPopover(displaySettings: displaySettings, openSettings: {
                            showingSettings = false
                            openSettings()
                        })
                    }
                }
            }
        }
    }

    private func selectSuggestion(_ suggestion: TypeaheadSuggestion) {
        switch suggestion.kind {
        case .topic, .subtopic:
            if let topicId = suggestion.topicId {
                store.searchText = ""
                searchFocused = false
                applySidebarSelection(topicId: topicId, subtopicId: nil)
            }
        case .channel:
            store.searchText = suggestion.text
            searchFocused = false
        }
    }

    private func applySidebarSelection(topicId: Int64, subtopicId: Int64?) {
        selectedCreatorSectionId = nil
        store.selectedTopicId = topicId
        store.selectedSubtopicId = isWatchMode ? nil : subtopicId
        displaySettings.scrollToTopicRequested = topicId
    }

    private func applyCreatorSelection(_ creator: CreatorSidebarEntry) {
        selectedCreatorSectionId = creator.sectionId
        let topicId: Int64?
        if isWatchMode {
            topicId = store.navigateToCreatorInWatch(
                channelId: creator.channelId.isEmpty ? nil : creator.channelId,
                channelName: creator.creatorName,
                preferredTopicId: creator.topicId
            )
        } else {
            topicId = store.navigateToCreator(channelId: creator.channelId, channelName: creator.creatorName, preferredTopicId: creator.topicId)
        }
        if let topicId {
            displaySettings.scrollToTopicRequested = topicId
        }
    }

    @ViewBuilder
    private func contextMenu(for topic: TopicViewModel) -> some View {
        Button("Rename…") { }

        Divider()

        Button("Split Topic…") {
            Task { await store.splitTopic(topic.id) }
        }

        if let selectedId = store.selectedTopicId, selectedId != topic.id {
            Button("Merge into \(store.topics.first { $0.id == selectedId }?.name ?? "selected")") {
                store.mergeTopics(sourceId: topic.id, intoId: selectedId)
            }
        }

        Divider()

        Button("Delete Topic", role: .destructive) {
            store.deleteTopic(topic.id)
        }
    }

    private func creatorEntries(for topic: TopicViewModel) -> [CreatorSidebarEntry] {
        if isWatchMode {
            let grouped = Dictionary(grouping: store.recentCandidateVideosForTopic(topic.id).filter { !$0.isPlaceholder }) { candidate in
                (candidate.channelId?.isEmpty == false ? candidate.channelId : nil) ?? candidate.channelName ?? "Unknown Creator"
            }

            return grouped.values.compactMap { group in
                guard let first = group.first else { return nil }
                let count = store.watchCandidateCountForChannel(first.channelId, channelName: first.channelName, inTopic: topic.id)
                guard count > 0 else { return nil }

                let knownChannel = first.channelId.flatMap { channelId in
                    store.channelsForTopic(topic.id).first(where: { $0.channelId == channelId })
                }

                return CreatorSidebarEntry(
                    sectionId: "creator-\(topic.id)-\((first.channelId?.isEmpty == false ? first.channelId! : first.channelName ?? "unknown"))",
                    topicId: topic.id,
                    channelId: first.channelId ?? "",
                    creatorName: first.channelName ?? "Unknown Creator",
                    count: count,
                    channelUrl: knownChannel?.channelUrl.flatMap(URL.init(string:)) ?? first.channelId.flatMap { URL(string: "https://www.youtube.com/channel/\($0)") },
                    channelIconUrl: knownChannel?.iconUrl.flatMap(URL.init(string:)) ?? first.channelIconUrl.flatMap(URL.init(string:))
                )
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.creatorName.localizedStandardCompare($1.creatorName) == .orderedAscending
                }
                return $0.count > $1.count
            }
        }

        let channels = store.channelsForTopic(topic.id)
        return channels.compactMap { channel in
            let count = store.videoCountForChannel(channel.channelId, inTopic: topic.id)
            guard count > 0 else { return nil }
            return CreatorSidebarEntry(
                sectionId: "creator-\(topic.id)-\(channel.name)",
                topicId: topic.id,
                channelId: channel.channelId,
                creatorName: channel.name,
                count: count,
                channelUrl: channel.channelUrl.flatMap(URL.init(string:)),
                channelIconUrl: channel.iconUrl.flatMap(URL.init(string:))
            )
        }
    }

    private func displayedCount(for topic: TopicViewModel) -> Int {
        guard isWatchMode else { return topic.videoCount }
        return store.recentCandidateVideosForTopic(topic.id).count
    }

    private func displayedCount(forSubtopic subtopic: TopicViewModel, parentTopicId: Int64) -> Int {
        guard isWatchMode else { return subtopic.videoCount }

        let candidateVideos = store.recentCandidateVideosForTopic(parentTopicId)
        guard !candidateVideos.isEmpty else { return 0 }

        let subtopicVideos = store.videosForTopic(subtopic.id)
        let subtopicChannelIds = Set(subtopicVideos.compactMap(\.channelId))
        let subtopicChannelNames = Set(subtopicVideos.compactMap(\.channelName))

        return candidateVideos.filter { candidate in
            if let channelId = candidate.channelId, subtopicChannelIds.contains(channelId) {
                return true
            }
            if let channelName = candidate.channelName, subtopicChannelNames.contains(channelName) {
                return true
            }
            return false
        }.count
    }
}

// MARK: - Settings Popover

private struct DisplayPopover: View {
    @Bindable var displaySettings: DisplaySettings
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Display")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Thumbnail Size")
                    .font(.body)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $displaySettings.thumbnailSize, in: 120...400, step: 20)
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Compressed Layout", isOn: Binding(
                get: { !displaySettings.showMetadata },
                set: { displaySettings.showMetadata = !$0 }
            ).animation(.easeInOut(duration: 0.25)))

            Divider()

            Button("Open Settings…") {
                openSettings()
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Topic Row

private struct TopicRow: View {
    let topic: TopicViewModel
    let count: Int
    var highlightTerms: [String] = []
    var isSubtopic: Bool = false
    var isSelected: Bool = false
    var isViewport: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: TopicTheme.iconName(for: topic.name))
                .font(.title3)
                .foregroundStyle(TopicTheme.iconColor(for: topic.name))
                .frame(width: 24)

            HighlightedText(topic.name, terms: highlightTerms)
                .lineLimit(1)

            Spacer()

            Text("\(count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.25)
        }
        if isViewport {
            return Color.accentColor.opacity(0.12)
        }
        return .clear
    }
}

private struct CreatorSidebarEntry: Identifiable {
    let sectionId: String
    let topicId: Int64
    let channelId: String
    let creatorName: String
    let count: Int
    let channelUrl: URL?
    let channelIconUrl: URL?

    var id: String { sectionId }
}

private struct CreatorSidebarRow: View {
    let creator: CreatorSidebarEntry
    var highlightTerms: [String] = []
    var isSelected: Bool = false
    var isViewport: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            channelIcon

            VStack(alignment: .leading, spacing: 2) {
                HighlightedText(creator.creatorName, terms: highlightTerms)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(creator.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.25)
        }
        if isViewport {
            return Color.accentColor.opacity(0.12)
        }
        return .clear
    }

    @ViewBuilder
    private var channelIcon: some View {
        if let channelIconUrl = creator.channelIconUrl {
            AsyncImage(url: channelIconUrl) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
        }
    }
}
