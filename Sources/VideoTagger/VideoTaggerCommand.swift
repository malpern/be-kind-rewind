import ArgumentParser
import Foundation
import TaggingKit

@main
struct VideoTaggerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video-tagger",
        abstract: "Organize YouTube videos into topics using Claude AI.",
        version: "0.2.0",
        subcommands: [Suggest.self, Reclassify.self, SubTopics.self, TopicsList.self, Preview.self, SplitTopic.self, MergeTopics.self, RenameTopic.self, DeleteTopic.self, Status.self, BackfillMetadata.self]
    )
}

// MARK: - Suggest

struct Suggest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze videos and suggest topic categories."
    )

    @Option(name: .shortAndLong, help: "Path to inventory.json.")
    var inventory: String

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .shortAndLong, help: "Number of topics to suggest.")
    var topics: Int = 12

    @Option(name: .long, help: "Anthropic API key (or set ANTHROPIC_API_KEY env var).")
    var apiKey: String?

    func run() async throws {
        let client: ClaudeClient
        if let apiKey {
            client = ClaudeClient(apiKey: apiKey)
        } else {
            client = try ClaudeClient()
        }
        let store = try TopicStore(path: db)
        let suggester = TopicSuggester(client: client)

        let snapshot = try InventoryLoader.load(from: URL(fileURLWithPath: inventory))
        try store.importVideos(snapshot.items)
        print("Imported \(snapshot.items.count) videos")

        let result = try await suggester.suggestAndClassify(
            videos: snapshot.items,
            targetTopicCount: topics
        ) { status in
            print("  \(status)")
        }

        // Store topics and assignments
        var topicIds: [String: Int64] = [:]
        for name in result.topics {
            topicIds[name] = try store.createTopic(name: name)
        }

        for assignment in result.assignments {
            if let tid = topicIds[assignment.topic] {
                try store.assignVideo(videoId: snapshot.items[assignment.videoIndex].videoId ?? "", toTopic: tid)
            }
        }

        // Print summary
        let storedTopics = try store.listTopics()
        let unassigned = try store.unassignedCount()
        print("\nTopics (\(storedTopics.count)):")
        for topic in storedTopics {
            print(String(format: "  [%2d] %4d videos  %@", topic.id, topic.videoCount, topic.name))
        }
        if unassigned > 0 {
            print(String(format: "       %4d unassigned", unassigned))
        }
        print("\nSaved to \(db). Use 'topics' to list, 'preview <id>' to browse.")
    }
}

// MARK: - Topics

struct TopicsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "topics",
        abstract: "List all topics with video counts."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    func run() throws {
        let store = try TopicStore(path: db)
        let topics = try store.listTopics()
        let unassigned = try store.unassignedCount()

        for topic in topics {
            print(String(format: "  [%2d] %4d videos  %@", topic.id, topic.videoCount, topic.name))
        }
        if unassigned > 0 {
            print(String(format: "       %4d unassigned", unassigned))
        }
    }
}

// MARK: - Preview

struct Preview: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Preview videos in a topic."
    )

    @Argument(help: "Topic ID.")
    var topicId: Int64

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .shortAndLong, help: "Max videos to show.")
    var limit: Int = 20

    func run() throws {
        let store = try TopicStore(path: db)
        let topics = try store.listTopics()
        guard let topic = topics.first(where: { $0.id == topicId }) else {
            print("Topic \(topicId) not found.")
            return
        }

        let videos = try store.videosForTopic(id: topicId, limit: limit)
        print("\(topic.name) (\(topic.videoCount) videos):")
        for video in videos {
            let channel = video.channelName.map { " [\($0)]" } ?? ""
            print("  \(video.title ?? "Untitled")\(channel)")
        }
        if topic.videoCount > limit {
            print("  ... and \(topic.videoCount - limit) more")
        }
    }
}

// MARK: - Split

struct SplitTopic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Split a topic into sub-topics (uses Sonnet)."
    )

    @Argument(help: "Topic ID to split.")
    var topicId: Int64

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .shortAndLong, help: "Number of sub-topics.")
    var into: Int = 3

    func run() async throws {
        let client = try ClaudeClient()
        let store = try TopicStore(path: db)
        let suggester = TopicSuggester(client: client)

        let topics = try store.listTopics()
        guard let topic = topics.first(where: { $0.id == topicId }) else {
            print("Topic \(topicId) not found.")
            return
        }

        let videos = try store.videosForTopic(id: topicId)
        let videoItems = videos.map { v in
            VideoItem(sourceIndex: v.sourceIndex, title: v.title, videoUrl: v.videoUrl,
                      videoId: v.videoId, channelName: v.channelName, metadataText: nil, unavailableKind: "none")
        }

        print("Splitting \"\(topic.name)\" (\(videos.count) videos)...")
        let subTopics = try await suggester.splitTopic(
            topicName: topic.name, videos: videoItems,
            videoIndices: videos.map(\.sourceIndex), targetSubTopics: into
        )

        try store.deleteTopic(id: topicId)
        for sub in subTopics {
            let newId = try store.createTopic(name: sub.name)
            try store.assignVideos(indices: sub.videoIndices, toTopic: newId)
        }

        print("Split into:")
        for sub in subTopics {
            print(String(format: "  %4d  %@", sub.videoIndices.count, sub.name))
        }
    }
}

// MARK: - Merge

struct MergeTopics: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge topics (keeps first topic's name)."
    )

    @Argument(help: "Topic IDs to merge.")
    var topicIds: [Int64]

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    func run() throws {
        guard topicIds.count >= 2 else {
            print("Need at least 2 topic IDs.")
            return
        }

        let store = try TopicStore(path: db)
        let keepId = topicIds[0]

        for mergeId in topicIds.dropFirst() {
            try store.mergeTopic(sourceId: mergeId, intoId: keepId)
        }

        let topics = try store.listTopics()
        if let merged = topics.first(where: { $0.id == keepId }) {
            print("Merged into \"\(merged.name)\" (\(merged.videoCount) videos)")
        }
    }
}

// MARK: - Rename

struct RenameTopic: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a topic."
    )

    @Argument(help: "Topic ID.")
    var topicId: Int64

    @Argument(help: "New name.")
    var name: String

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    func run() throws {
        let store = try TopicStore(path: db)
        try store.renameTopic(id: topicId, to: name)
        print("Renamed to \"\(name)\"")
    }
}

// MARK: - Delete

struct DeleteTopic: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a topic (videos become unassigned)."
    )

    @Argument(help: "Topic ID.")
    var topicId: Int64

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    func run() throws {
        let store = try TopicStore(path: db)
        try store.deleteTopic(id: topicId)
        print("Deleted. Videos are now unassigned.")
    }
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show database status."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    func run() throws {
        let store = try TopicStore(path: db)
        let topics = try store.listTopics()
        let total = try store.totalVideoCount()
        let unassigned = try store.unassignedCount()
        let pending = try store.pendingSyncPlan()

        print("Videos: \(total) total, \(total - unassigned) assigned, \(unassigned) unassigned")
        print("Topics: \(topics.count)")
        print("Pending sync: \(pending.count) actions")
    }
}

// MARK: - Reclassify

struct Reclassify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Classify unassigned videos against existing topics."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .long, help: "Anthropic API key.")
    var apiKey: String?

    func run() async throws {
        let client: ClaudeClient
        if let apiKey { client = ClaudeClient(apiKey: apiKey) } else { client = try ClaudeClient() }
        let store = try TopicStore(path: db)
        let suggester = TopicSuggester(client: client)

        let unassigned = try store.unassignedVideoItems()
        guard !unassigned.isEmpty else {
            print("No unassigned videos.")
            return
        }

        let topics = try store.listTopics()
        let topicNames = topics.map(\.name)
        print("Classifying \(unassigned.count) unassigned videos against \(topicNames.count) topics...")

        let assignments = try await suggester.classifyVideos(
            videos: unassigned,
            topics: topicNames
        ) { batch, total in
            print("  Batch \(batch)/\(total)...")
        }

        var assignedCount = 0
        for a in assignments {
            if let tid = try store.topicIdByName(a.topic) {
                let vid = unassigned[a.videoIndex].videoId ?? ""
                guard !vid.isEmpty else { continue }
                try store.assignVideo(videoId: vid, toTopic: tid)
                assignedCount += 1
            }
        }

        let remaining = try store.unassignedCount()
        print("Assigned \(assignedCount) videos. \(remaining) still unassigned.")
    }
}

// MARK: - Backfill Metadata

struct BackfillMetadata: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backfill-metadata",
        abstract: "Fetch view count, publish date, and duration from YouTube Data API."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .long, help: "YouTube/Google API key (or set YOUTUBE_API_KEY / GOOGLE_API_KEY env var).")
    var apiKey: String?

    @Flag(name: .long, help: "Re-fetch metadata for all videos, not just missing ones.")
    var all = false

    func run() async throws {
        let store = try TopicStore(path: db)
        let youtube: YouTubeClient
        if let apiKey {
            youtube = YouTubeClient(apiKey: apiKey)
        } else {
            youtube = try YouTubeClient()
        }

        let ids: [String]
        if all {
            ids = try store.allVideoIds()
            print("Fetching metadata for all \(ids.count) videos...")
        } else {
            ids = try store.videoIdsMissingMetadata()
            if ids.isEmpty {
                print("All videos already have metadata.")
                return
            }
            print("Fetching metadata for \(ids.count) videos missing metadata...")
        }

        let metadata = try await youtube.fetchAllVideoMetadata(ids: ids) { batch, total in
            print("  Batch \(batch)/\(total)...")
        }

        // Collect unique channel IDs and fetch their icons
        let channelIds = Array(Set(metadata.compactMap(\.channelId)))
        var channelIcons: [String: String] = [:]
        if !channelIds.isEmpty {
            print("Fetching channel icons for \(channelIds.count) channels...")
            let iconBatches = stride(from: 0, to: channelIds.count, by: 50).map {
                Array(channelIds[$0..<min($0 + 50, channelIds.count)])
            }
            for batch in iconBatches {
                let icons = try await youtube.fetchChannelThumbnails(channelIds: batch)
                channelIcons.merge(icons) { _, new in new }
            }
        }

        var updated = 0
        for m in metadata {
            let iconUrl = m.channelId.flatMap { channelIcons[$0] }
            try store.updateVideoMetadata(
                videoId: m.videoId,
                viewCount: m.formattedViewCount,
                publishedAt: m.formattedDate,
                duration: m.formattedDuration,
                channelIconUrl: iconUrl
            )
            updated += 1
        }

        let missing = ids.count - updated
        print("Updated \(updated) videos with metadata and \(channelIcons.count) channel icons.")
        if missing > 0 {
            print("\(missing) videos had no YouTube data (possibly deleted/private).")
        }
    }
}

// MARK: - SubTopics

struct SubTopics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subtopics",
        abstract: "Discover sub-topics within a category (does not split — preview only)."
    )

    @Argument(help: "Topic ID to analyze.")
    var topicId: Int64

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .shortAndLong, help: "Number of sub-topics to suggest.")
    var count: Int = 5

    @Option(name: .long, help: "Anthropic API key.")
    var apiKey: String?

    func run() async throws {
        let client: ClaudeClient
        if let apiKey { client = ClaudeClient(apiKey: apiKey) } else { client = try ClaudeClient() }
        let store = try TopicStore(path: db)
        let suggester = TopicSuggester(client: client)

        let topics = try store.listTopics()
        guard let topic = topics.first(where: { $0.id == topicId }) else {
            print("Topic \(topicId) not found.")
            return
        }

        let videos = try store.videosForTopic(id: topicId)
        let videoItems = videos.map { v in
            VideoItem(sourceIndex: v.sourceIndex, title: v.title, videoUrl: v.videoUrl,
                      videoId: v.videoId, channelName: v.channelName, metadataText: nil, unavailableKind: "none")
        }

        print("Analyzing \"\(topic.name)\" (\(videos.count) videos) for sub-topics...")

        // Use Sonnet to discover sub-topics from a sample (preview only, no DB changes)
        let sampleTitles = videoItems.prefix(150).map { v in
            let channel = v.channelName.map { " [\($0)]" } ?? ""
            return "\(v.title ?? "Untitled")\(channel)"
        }.joined(separator: "\n")

        let prompt = """
        This YouTube playlist topic "\(topic.name)" has \(videos.count) videos. Here's a sample:

        \(sampleTitles)

        Suggest exactly \(count) sub-topics that would help organize videos within this category.
        For each sub-topic, estimate how many of the \(videos.count) videos would fit.

        Return ONLY valid JSON:
        [{"name": "Sub-Topic Name", "estimatedCount": 100, "description": "Brief description"}]
        """

        let response = try await client.complete(
            prompt: prompt,
            system: "You are a video librarian discovering sub-categories within a topic. Return only valid JSON.",
            model: .sonnet,
            maxTokens: 1024
        )

        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        struct SubTopic: Decodable {
            let name: String
            let estimatedCount: Int?
            let description: String?
        }

        let subTopics = try JSONDecoder().decode([SubTopic].self, from: cleaned.data(using: .utf8)!)

        print("\nSuggested sub-topics for \"\(topic.name)\":")
        for sub in subTopics {
            let count = sub.estimatedCount.map { "~\($0) videos" } ?? ""
            let desc = sub.description.map { " — \($0)" } ?? ""
            print("  \(sub.name) \(count)\(desc)")
        }
        print("\nThis is a preview — use 'split \(topicId)' to actually split the topic.")
    }
}
