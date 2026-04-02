import SwiftUI

struct TopicSidebar: View {
    @Bindable var store: OrganizerStore
    @Bindable var displaySettings: DisplaySettings
    @State private var showingSettings = false

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

    var body: some View {
        List(selection: $store.selectedTopicId) {
            Section {
                ForEach(filteredTopics) { topic in
                    TopicRow(topic: topic, highlightTerms: store.parsedQuery.includeTerms)
                        .tag(topic.id)
                        .contextMenu { contextMenu(for: topic) }
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
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search videos & topics")
        .navigationTitle("Be Kind, Rewind")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showingSettings.toggle() } label: {
                    Image(systemName: "gearshape")
                }
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    SettingsPopover(displaySettings: displaySettings)
                }
            }
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
                    .font(.subheadline)
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

            Toggle("Show video metadata", isOn: $displaySettings.showMetadata.animation(.easeInOut(duration: 0.25)))
        }
        .padding(16)
        .frame(width: 260)
    }
}

// MARK: - Topic Row

private struct TopicRow: View {
    let topic: TopicViewModel
    var highlightTerms: [String] = []

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: topic.name))
                .font(.title3)
                .foregroundStyle(iconColor(for: topic.name))
                .frame(width: 24)

            HighlightedText(topic.name, terms: highlightTerms)
                .lineLimit(1)

            Spacer()

            Text("\(topic.videoCount)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func iconName(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("keyboard") { return "keyboard" }
        if lower.contains("claude") || lower.contains("anthropic") { return "brain" }
        if lower.contains("ai") || lower.contains("agent") || lower.contains("llm") { return "cpu" }
        if lower.contains("vim") || lower.contains("terminal") { return "terminal" }
        if lower.contains("swift") || lower.contains("ios") { return "swift" }
        if lower.contains("mac") || lower.contains("apple") { return "desktopcomputer" }
        if lower.contains("web") { return "globe" }
        if lower.contains("embedded") || lower.contains("electronic") || lower.contains("pcb") { return "chip" }
        if lower.contains("linux") || lower.contains("devops") { return "server.rack" }
        if lower.contains("retro") || lower.contains("vintage") { return "clock.arrow.trianglehead.counterclockwise.rotate.90" }
        if lower.contains("3d print") { return "cube" }
        if lower.contains("home auto") { return "house" }
        if lower.contains("geopolit") || lower.contains("current event") { return "globe.americas" }
        if lower.contains("finance") || lower.contains("retire") { return "chart.line.uptrend.xyaxis" }
        if lower.contains("health") || lower.contains("lifestyle") { return "heart" }
        if lower.contains("entertainment") || lower.contains("pop culture") { return "film" }
        if lower.contains("productiv") || lower.contains("creative") || lower.contains("learning") { return "lightbulb" }
        if lower.contains("personal growth") || lower.contains("philosophy") { return "person.fill" }
        if lower.contains("programming") || lower.contains("software") { return "chevron.left.forwardslash.chevron.right" }
        if lower.contains("tech") || lower.contains("gadget") { return "wrench.and.screwdriver" }
        if lower.contains("cursor") || lower.contains("ide") || lower.contains("coding tool") { return "hammer" }
        return "folder"
    }

    private func iconColor(for name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("keyboard") { return .purple }
        if lower.contains("claude") || lower.contains("anthropic") { return .orange }
        if lower.contains("ai") || lower.contains("agent") || lower.contains("llm") { return .blue }
        if lower.contains("vim") || lower.contains("terminal") { return .green }
        if lower.contains("swift") || lower.contains("ios") { return .orange }
        if lower.contains("mac") || lower.contains("apple") { return .gray }
        if lower.contains("web") { return .cyan }
        if lower.contains("embedded") || lower.contains("electronic") { return .yellow }
        if lower.contains("retro") { return .brown }
        if lower.contains("health") { return .red }
        if lower.contains("finance") { return .green }
        if lower.contains("entertainment") { return .pink }
        return .secondary
    }
}
