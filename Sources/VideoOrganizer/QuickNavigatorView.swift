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
                List(results, selection: $selection) { item in
                    Button {
                        activate(item)
                    } label: {
                        navigatorRow(item)
                    }
                    .buttonStyle(.plain)
                    .tag(item.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(width: 620, height: 420)
        .onAppear {
            selection = results.first?.id
            DispatchQueue.main.async {
                queryFocused = true
            }
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

    private func matchingTopicItems(for query: String) -> [QuickNavigatorItem] {
        let filtered = store.topics.filter { topic in
            query.isEmpty || topic.name.localizedStandardContains(query)
        }

        return filtered
            .sorted { lhs, rhs in
                if lhs.videoCount != rhs.videoCount {
                    return lhs.videoCount > rhs.videoCount
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(8)
            .map { topic in
                QuickNavigatorItem(
                    kind: .topic,
                    title: topic.name,
                    subtitle: nil,
                    countText: "\(topic.videoCount)",
                    topicId: topic.id,
                    parentTopicId: nil,
                    playlist: nil
                )
            }
    }

    private func matchingSubtopicItems(for query: String) -> [QuickNavigatorItem] {
        guard store.pageDisplayMode != .watchCandidates else { return [] }

        let matches = store.topics.flatMap { topic in
            topic.subtopics.compactMap { subtopic -> QuickNavigatorItem? in
                guard query.isEmpty || subtopic.name.localizedStandardContains(query) else { return nil }
                return QuickNavigatorItem(
                    kind: .subtopic,
                    title: subtopic.name,
                    subtitle: topic.name,
                    countText: "\(subtopic.videoCount)",
                    topicId: subtopic.id,
                    parentTopicId: topic.id,
                    playlist: nil
                )
            }
        }

        return Array(matches.prefix(8))
    }

    private func matchingPlaylistItems(for query: String) -> [QuickNavigatorItem] {
        store.knownPlaylists()
            .filter { playlist in
                query.isEmpty || playlist.title.localizedStandardContains(query)
            }
            .sorted { lhs, rhs in
                if (lhs.videoCount ?? 0) != (rhs.videoCount ?? 0) {
                    return (lhs.videoCount ?? 0) > (rhs.videoCount ?? 0)
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(8)
            .map { playlist in
                QuickNavigatorItem(
                    kind: .playlist,
                    title: playlist.title,
                    subtitle: playlist.visibility?.capitalized,
                    countText: playlist.videoCount.map(String.init),
                    topicId: nil,
                    parentTopicId: nil,
                    playlist: playlist
                )
            }
    }
}
