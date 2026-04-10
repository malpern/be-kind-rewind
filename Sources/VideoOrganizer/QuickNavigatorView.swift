import SwiftUI
import TaggingKit

struct QuickNavigatorView: View {
    @Bindable var store: OrganizerStore
    @Bindable var displaySettings: DisplaySettings
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selection: QuickNavigatorItem.ID?
    @FocusState private var queryFocused: Bool

    private var results: [QuickNavigatorItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let topicItems = matchingTopicItems(for: trimmed)
        let subtopicItems = matchingSubtopicItems(for: trimmed)
        let playlistItems = matchingPlaylistItems(for: trimmed)
        return topicItems + subtopicItems + playlistItems
    }

    private var sections: [QuickNavigatorSection] {
        var grouped: [QuickNavigatorSection] = []
        let topics = results.filter { $0.kind == .topic }
        let subtopics = results.filter { $0.kind == .subtopic }
        let playlists = results.filter { $0.kind == .playlist }

        if !topics.isEmpty {
            grouped.append(QuickNavigatorSection(title: "Topics", items: topics))
        }
        if !subtopics.isEmpty {
            grouped.append(QuickNavigatorSection(title: "Subtopics", items: subtopics))
        }
        if !playlists.isEmpty {
            grouped.append(QuickNavigatorSection(title: "Playlists", items: playlists))
        }

        return grouped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Jump to a topic or playlist", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit {
                        activateSelectedOrFirstResult()
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if results.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "magnifyingglass",
                    description: Text("Try a topic or playlist name.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                Button {
                                    activate(item)
                                } label: {
                                    navigatorRow(item)
                                }
                                .buttonStyle(.plain)
                                .tag(item.id)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(width: 620, height: 420)
        .onMoveCommand(perform: handleMoveCommand)
        .onExitCommand {
            isPresented = false
        }
        .onAppear {
            AppLogger.app.info("Quick navigator presented")
            selection = results.first?.id
            DispatchQueue.main.async {
                queryFocused = true
            }
        }
        .onDisappear {
            AppLogger.app.info("Quick navigator dismissed")
        }
        .onChange(of: query) { _, _ in
            selection = results.first?.id
        }
    }

    @ViewBuilder
    private func navigatorRow(_ item: QuickNavigatorItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .foregroundStyle(item.kind == .topic ? TopicTheme.iconColor(for: item.title) : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let countText = item.countText {
                Text(countText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func activateSelectedOrFirstResult() {
        if let selection,
           let item = results.first(where: { $0.id == selection }) {
            activate(item)
            return
        }
        if let first = results.first {
            activate(first)
        }
    }

    private func activate(_ item: QuickNavigatorItem) {
        AppLogger.commands.info(
            "Quick navigator activated \(item.kind.rawValue, privacy: .public): \(item.title, privacy: .public)"
        )
        switch item.kind {
        case .topic:
            if let topicId = item.topicId {
                store.clearPlaylistFilter()
                store.selectedTopicId = topicId
                store.selectedSubtopicId = nil
                displaySettings.scrollToTopicRequested = topicId
            }
        case .subtopic:
            if let subtopicId = item.topicId,
               let parentTopicId = item.parentTopicId {
                store.clearPlaylistFilter()
                store.selectedTopicId = parentTopicId
                store.selectedSubtopicId = store.pageDisplayMode == .watchCandidates ? nil : subtopicId
                displaySettings.scrollToTopicRequested = parentTopicId
            }
        case .playlist:
            if let playlist = item.playlist {
                store.applyPlaylistFilter(playlist)
            }
        }
        isPresented = false
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .down:
            moveSelection(by: 1)
        case .up:
            moveSelection(by: -1)
        default:
            break
        }
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        guard let selection,
              let currentIndex = results.firstIndex(where: { $0.id == selection }) else {
            self.selection = results.first?.id
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), results.count - 1)
        self.selection = results[nextIndex].id
    }

    private func matchingTopicItems(for query: String) -> [QuickNavigatorItem] {
        store.topics
            .compactMap { topic -> (QuickNavigatorItem, Int)? in
                let score = matchScore(for: topic.name, query: query)
                guard score != nil else { return nil }
                return (
                    QuickNavigatorItem(
                        kind: .topic,
                        title: topic.name,
                        subtitle: nil,
                        countText: "\(topic.videoCount)",
                        topicId: topic.id,
                        parentTopicId: nil,
                        playlist: nil
                    ),
                    score ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                let lhsCount = Int(lhs.0.countText ?? "") ?? 0
                let rhsCount = Int(rhs.0.countText ?? "") ?? 0
                if lhsCount != rhsCount {
                    return lhsCount > rhsCount
                }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            .prefix(8)
            .map(\.0)
    }

    private func matchingSubtopicItems(for query: String) -> [QuickNavigatorItem] {
        guard store.pageDisplayMode != .watchCandidates else { return [] }

        let matches = store.topics.flatMap { topic in
            topic.subtopics.compactMap { subtopic -> (QuickNavigatorItem, Int)? in
                let score = matchScore(for: subtopic.name, query: query)
                guard score != nil else { return nil }
                return (
                    QuickNavigatorItem(
                        kind: .subtopic,
                        title: subtopic.name,
                        subtitle: topic.name,
                        countText: "\(subtopic.videoCount)",
                        topicId: subtopic.id,
                        parentTopicId: topic.id,
                        playlist: nil
                    ),
                    score ?? 0
                )
            }
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            .prefix(8)
            .map(\.0)
    }

    private func matchingPlaylistItems(for query: String) -> [QuickNavigatorItem] {
        store.knownPlaylists()
            .compactMap { playlist -> (QuickNavigatorItem, Int)? in
                let score = matchScore(for: playlist.title, query: query)
                guard score != nil else { return nil }
                return (
                    QuickNavigatorItem(
                        kind: .playlist,
                        title: playlist.title,
                        subtitle: playlist.visibility?.capitalized,
                        countText: playlist.videoCount.map(String.init),
                        topicId: nil,
                        parentTopicId: nil,
                        playlist: playlist
                    ),
                    score ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                let lhsCount = lhs.0.playlist?.videoCount ?? 0
                let rhsCount = rhs.0.playlist?.videoCount ?? 0
                if lhsCount != rhsCount {
                    return lhsCount > rhsCount
                }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            .prefix(8)
            .map(\.0)
    }

    private func matchScore(for candidate: String, query: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 1 }

        let lowerCandidate = candidate.lowercased()
        let lowerQuery = trimmed.lowercased()

        if lowerCandidate == lowerQuery {
            return 4
        }
        if lowerCandidate.hasPrefix(lowerQuery) {
            return 3
        }
        if lowerCandidate.contains(" \(lowerQuery)") {
            return 2
        }
        if lowerCandidate.localizedStandardContains(lowerQuery) {
            return 1
        }
        return nil
    }
}

private struct QuickNavigatorSection: Identifiable {
    let title: String
    let items: [QuickNavigatorItem]

    var id: String { title }
}
