import SwiftUI

/// Left sidebar listing topics with video counts, subtopic expansion, and Saved/Watch mode toggle.
struct TopicSidebar: View {
    @Bindable var store: OrganizerStore
    @Bindable var displaySettings: DisplaySettings
    @Environment(\.openSettings) private var openSettings
    @State private var showingSettings = false
    @State private var expandedTopicId: Int64? = nil
    @State private var selectedCreatorSectionId: String?
    @State private var renamingTopicId: Int64?
    @State private var renameText: String = ""
    @State private var searchBarHeight: CGFloat = 0
    @State private var sidebarPullDistance: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @FocusState private var renameFocused: Bool

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
            store.topicMatchesSearch(topic, query: query)
        }
    }

    /// In Watch mode, selection is topic-only; in Saved mode, subtopic selection takes priority.
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

    private var searchRevealThreshold: CGFloat {
        max(searchBarHeight * 0.7, 28)
    }

    private var showsSearchField: Bool {
        searchFocused || !store.searchText.isEmpty || sidebarPullDistance > searchRevealThreshold
    }

    private var collapsedSearchOffset: CGFloat {
        showsSearchField ? 0 : -(searchBarHeight + 12)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: SidebarPullDistancePreferenceKey.self, value: max(0, proxy.frame(in: .named("sidebarScroll")).minY))
                    }
                    .frame(height: 0)

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
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear {
                                        searchBarHeight = proxy.size.height
                                    }
                                    .onChange(of: proxy.size.height) { _, newValue in
                                        searchBarHeight = newValue
                                    }
                            }
                        )
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
                    .offset(y: collapsedSearchOffset)
                    .padding(.bottom, collapsedSearchOffset)

                    HStack(spacing: 6) {
                        if store.watchRefreshTotalTopics > 0 {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Refreshing \(store.watchRefreshCompletedTopics)/\(store.watchRefreshTotalTopics)")
                                .font(.subheadline.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(filteredTopics.count) Topics")
                                .font(.subheadline.weight(.medium))
                        }
                        Spacer()
                        if store.parsedQuery.isEmpty {
                            Text("\(store.totalVideoCount) videos")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("\(store.searchResultCount) results")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 6)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredTopics) { topic in
                            topicRowContent(topic)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    guard renamingTopicId == nil else { return }
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
                                    guard renamingTopicId == nil else { return }
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
            .coordinateSpace(name: "sidebarScroll")
            .focusable()
            .focused($listFocused)
            .onPreferenceChange(SidebarPullDistancePreferenceKey.self) { sidebarPullDistance = $0 }
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
                AppLogger.commands.info("Focusing topic sidebar")
                listFocused = true
            }
            .onChange(of: displaySettings.searchRequested) { _, requested in
                guard requested else { return }
                displaySettings.searchRequested = false
                AppLogger.commands.info("Revealing sidebar search field")
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
                        showingSettings.toggle()
                        AppLogger.app.info("Toggled view options popover: \(showingSettings, privacy: .public)")
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
                            AppLogger.app.info("Opening settings from sidebar view options")
                            openSettings()
                        })
                    }
                }
            }
        }
    }

    /// Navigates to the selected typeahead suggestion (topic, subtopic, channel filter,
    /// or `from:` creator-handle insertion).
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
        case .fromCreator:
            // Replace the trailing `from:partial` (or `from:`) token with the
            // canonical form. Prefer @handle when available, fall back to the
            // display name (quoted if it contains a space).
            let resolvedToken = makeFromToken(for: suggestion)
            store.searchText = replaceTrailingFromToken(in: store.searchText, with: resolvedToken)
            // Keep focus so the user can continue typing other terms (e.g. text after the from:).
        }
    }

    /// Builds the canonical `from:...` token for a creator suggestion. Prefers the
    /// stable @handle when present; falls back to the display name (quoted if it
    /// contains a space so the parser preserves it as one token).
    private func makeFromToken(for suggestion: TypeaheadSuggestion) -> String {
        if let handle = suggestion.handle, !handle.isEmpty {
            // Ensure single leading @
            let normalized = handle.hasPrefix("@") ? handle : "@\(handle)"
            return "from:\(normalized)"
        }
        if suggestion.text.contains(" ") {
            return "from:\"\(suggestion.text)\""
        }
        return "from:\(suggestion.text)"
    }

    /// Replaces the trailing whitespace-separated token starting with `from:` in the
    /// given search text with `replacement`. Preserves any other terms before it.
    private func replaceTrailingFromToken(in text: String, with replacement: String) -> String {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard let last = parts.last, last.hasPrefix("from:") else {
            return text + " " + replacement
        }
        let prefixParts = parts.dropLast()
        if prefixParts.isEmpty {
            return replacement + " "
        }
        return prefixParts.joined(separator: " ") + " " + replacement + " "
    }

    private func applySidebarSelection(topicId: Int64, subtopicId: Int64?) {
        selectedCreatorSectionId = nil
        store.selectedTopicId = topicId
        store.selectedSubtopicId = isWatchMode ? nil : subtopicId
        displaySettings.scrollToTopicRequested = topicId
    }

    @ViewBuilder
    private func topicRowContent(_ topic: TopicViewModel) -> some View {
        if renamingTopicId == topic.id {
            HStack(spacing: 10) {
                Image(systemName: TopicTheme.iconName(for: topic.name))
                    .font(.title3)
                    .foregroundStyle(TopicTheme.iconColor(for: topic.name))
                    .frame(width: 24)

                TextField("Topic name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renamingTopicId = nil }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.25))
            )
        } else {
            TopicRow(
                topic: topic,
                count: displayedCount(for: topic),
                highlightTerms: store.parsedQuery.includeTerms,
                isSelected: isSelected(topic),
                isViewport: isViewportTopic(topic)
            )
        }
    }

    private func commitRename() {
        guard let topicId = renamingTopicId else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            store.renameTopic(topicId, to: trimmed)
        }
        renamingTopicId = nil
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
        Button("Rename…") {
            renameText = topic.name
            renamingTopicId = topic.id
            renameFocused = true
        }

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

    /// Builds the inline creator list for expanded topic rows, combining saved and watch candidate creators.
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

    /// Returns the count shown next to a topic row — saved video count or watch candidate count.
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

private struct SidebarPullDistancePreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Slider(value: $displaySettings.thumbnailSize, in: 120...400, step: 20)
                    Image(systemName: "photo")
                        .font(.subheadline)
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
