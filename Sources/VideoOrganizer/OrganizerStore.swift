import Foundation
import Observation
import TaggingKit

/// Main data store bridging TaggingKit's SQLite backend to SwiftUI's Observation.
@MainActor
@Observable
final class OrganizerStore {
    private(set) var topics: [TopicViewModel] = []
    private(set) var totalVideoCount: Int = 0
    private(set) var unassignedCount: Int = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    // Selected state
    var selectedTopicId: Int64?
    var selectedVideoIds: Set<String> = []

    private let store: TopicStore
    private let suggester: TopicSuggester?

    init(dbPath: String, claudeClient: ClaudeClient? = nil) throws {
        self.store = try TopicStore(path: dbPath)
        self.suggester = claudeClient.map { TopicSuggester(client: $0) }
    }

    // MARK: - Loading

    func loadTopics() {
        do {
            let summaries = try store.listTopics()
            topics = summaries.map { TopicViewModel(id: $0.id, name: $0.name, videoCount: $0.videoCount) }
            totalVideoCount = try store.totalVideoCount()
            unassignedCount = try store.unassignedCount()
            if selectedTopicId == nil, let first = topics.first {
                selectedTopicId = first.id
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func videosForTopic(_ topicId: Int64, limit: Int? = nil) -> [VideoViewModel] {
        do {
            let stored = try store.videosForTopic(id: topicId, limit: limit)
            return stored.map {
                VideoViewModel(
                    videoId: $0.videoId,
                    title: $0.title ?? "Untitled",
                    channelName: $0.channelName,
                    videoUrl: $0.videoUrl,
                    sourceIndex: $0.sourceIndex,
                    topicId: $0.topicId
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    // MARK: - Topic Operations

    func renameTopic(_ topicId: Int64, to newName: String) {
        do {
            try store.renameTopic(id: topicId, to: newName)
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTopic(_ topicId: Int64) {
        do {
            try store.deleteTopic(id: topicId)
            if selectedTopicId == topicId { selectedTopicId = nil }
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func mergeTopics(sourceId: Int64, intoId: Int64) {
        do {
            try store.mergeTopic(sourceId: sourceId, intoId: intoId)
            if selectedTopicId == sourceId { selectedTopicId = intoId }
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveVideo(videoId: String, toTopicId: Int64) {
        do {
            try store.assignVideo(videoId: videoId, toTopic: toTopicId)
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveVideos(videoIds: Set<String>, toTopicId: Int64) {
        do {
            for vid in videoIds {
                try store.assignVideo(videoId: vid, toTopic: toTopicId)
            }
            selectedVideoIds = []
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - AI Operations

    func discoverSubTopics(for topicId: Int64, count: Int = 5) async -> [SubTopicSuggestion] {
        // TODO: Wire up to TopicSuggester.splitTopic for sub-topic discovery
        return []
    }

    func splitTopic(_ topicId: Int64, into count: Int = 3) async {
        guard let suggester else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let videos = try store.videosForTopic(id: topicId)
            let topic = topics.first { $0.id == topicId }
            let videoItems = videos.map { v in
                VideoItem(sourceIndex: v.sourceIndex, title: v.title, videoUrl: v.videoUrl,
                          videoId: v.videoId, channelName: v.channelName, metadataText: nil, unavailableKind: "none")
            }

            let subTopics = try await suggester.splitTopic(
                topicName: topic?.name ?? "",
                videos: videoItems,
                videoIndices: videos.map(\.sourceIndex),
                targetSubTopics: count
            )

            try store.deleteTopic(id: topicId)
            for sub in subTopics {
                let newId = try store.createTopic(name: sub.name)
                try store.assignVideos(indices: sub.videoIndices, toTopic: newId)
            }

            selectedTopicId = nil
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - View Models (value types for SwiftUI)

struct TopicViewModel: Identifiable, Hashable {
    let id: Int64
    var name: String
    var videoCount: Int
}

struct VideoViewModel: Identifiable, Hashable {
    let videoId: String
    let title: String
    let channelName: String?
    let videoUrl: String?
    let sourceIndex: Int
    let topicId: Int64?

    var id: String { videoId }

    var thumbnailUrl: URL? {
        guard let videoId = videoUrl.flatMap({ URL(string: $0) })?.queryItems?["v"] ?? self.videoId.nilIfEmpty else {
            return nil
        }
        return URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
    }
}

struct SubTopicSuggestion: Identifiable {
    let id = UUID()
    let name: String
    let estimatedCount: Int
    let description: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension URL {
    var queryItems: [String: String]? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [:]) { $0[$1.name] = $1.value }
    }
}
