import SwiftUI

struct TopicSidebar: View {
    @Bindable var store: OrganizerStore
    @Bindable var displaySettings: DisplaySettings
    @State private var showingSettings = false
    @State private var expandedTopicId: Int64? = nil
    @FocusState private var searchFocused: Bool

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

    /// Selection binding that distinguishes main topics from subtopics.
    /// Clicking a subtopic sets both selectedTopicId (parent) and selectedSubtopicId.
    /// Clicking a main topic clears selectedSubtopicId.
    private var sidebarSelection: Binding<Int64?> {
        Binding(
            get: { store.selectedSubtopicId ?? store.selectedTopicId },
            set: { newValue in
                guard let id = newValue else {
                    store.selectedTopicId = nil
                    store.selectedSubtopicId = nil
                    return
                }
                // Check if this is a subtopic
                for topic in store.topics {
                    if topic.subtopics.contains(where: { $0.id == id }) {
                        store.selectedTopicId = topic.id
                        store.selectedSubtopicId = id
                        return
                    }
                }
                // It's a main topic
                store.selectedTopicId = id
                store.selectedSubtopicId = nil
            }
        )
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: sidebarSelection) {
                // Hidden search field — scroll up to reveal
                Section {
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .id("search-field")
                }

                Section {
                    ForEach(filteredTopics) { topic in
                        // Parent topic row — tap to expand/collapse and select
                        TopicRow(topic: topic, highlightTerms: store.parsedQuery.includeTerms)
                            .tag(topic.id)
                            .contextMenu { contextMenu(for: topic) }
                            .onDoubleClick {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expandedTopicId == topic.id {
                                        expandedTopicId = nil
                                    } else {
                                        expandedTopicId = topic.id
                                    }
                                }
                            }

                        // Subtopics — shown when this topic is expanded
                        if expandedTopicId == topic.id && !topic.subtopics.isEmpty {
                            ForEach(topic.subtopics) { sub in
                                TopicRow(topic: sub, highlightTerms: store.parsedQuery.includeTerms, isSubtopic: true)
                                    .tag(sub.id)
                                    .padding(.leading, 20)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                    }
                } header: {
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
                }

                if store.unassignedCount > 0 && store.parsedQuery.isEmpty {
                    Section {
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
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    scrollProxy.scrollTo(filteredTopics.first?.id, anchor: .top)
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
                        displaySettings.toast.show("Display Settings", icon: "gearshape")
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Display settings")
                    .accessibilityIdentifier("displaySettings")
                    .accessibilityLabel("Display settings")
                    .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                        SettingsPopover(displaySettings: displaySettings)
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
                store.selectedTopicId = topicId
            }
        case .channel:
            store.searchText = suggestion.text
            searchFocused = false
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
}

// MARK: - Settings Popover

private struct SettingsPopover: View {
    @Bindable var displaySettings: DisplaySettings

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
        }
        .padding(16)
        .frame(width: 260)
    }
}

// MARK: - Topic Row

private struct TopicRow: View {
    let topic: TopicViewModel
    var highlightTerms: [String] = []
    var isSubtopic: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: TopicTheme.iconName(for: topic.name))
                .font(.title3)
                .foregroundStyle(TopicTheme.iconColor(for: topic.name))
                .frame(width: 24)

            HighlightedText(topic.name, terms: highlightTerms)
                .lineLimit(1)

            Spacer()

            Text("\(topic.videoCount)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("topic-\(topic.id)")
        .accessibilityLabel("\(topic.name), \(topic.videoCount) videos")
    }
}
