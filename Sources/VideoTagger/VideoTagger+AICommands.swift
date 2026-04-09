import ArgumentParser
import Foundation
import TaggingKit

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

// MARK: - Reclassify All

struct ReclassifyAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reclassify-all",
        abstract: "Reclassify ALL videos against existing topics using Sonnet for better accuracy."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .long, help: "Anthropic API key.")
    var apiKey: String?

    @Option(name: .long, help: "Batch size for classification (smaller = more accurate).")
    var batchSize: Int = 100

    func run() async throws {
        let client: ClaudeClient
        if let apiKey { client = ClaudeClient(apiKey: apiKey) } else { client = try ClaudeClient() }
        let store = try TopicStore(path: db)
        let suggester = TopicSuggester(client: client)

        let topics = try store.listTopics()
        let topicNames = topics.map(\.name)

        // Clear subtopics first (will regenerate after)
        print("Clearing existing subtopics...")
        for topic in topics {
            try store.deleteSubtopics(parentId: topic.id)
        }

        let allVideos = try store.allVideoItems()
        print("Reclassifying \(allVideos.count) videos against \(topicNames.count) topics using Sonnet...")
        print("Batch size: \(batchSize) (\(allVideos.count / batchSize + 1) batches)\n")

        let assignments = try await suggester.classifyVideos(
            videos: allVideos,
            topics: topicNames,
            batchSize: batchSize,
            model: .sonnet
        ) { batch, total in
            print("  Batch \(batch)/\(total)...")
        }

        // Reassign all videos
        var topicIdMap: [String: Int64] = [:]
        for t in topics { topicIdMap[t.name] = t.id }

        var assignedCount = 0
        for a in assignments {
            guard let tid = topicIdMap[a.topic] else { continue }
            let vid = allVideos[a.videoIndex].videoId ?? ""
            guard !vid.isEmpty else { continue }
            try store.assignVideo(videoId: vid, toTopic: tid)
            assignedCount += 1
        }

        let unassigned = try store.unassignedCount()
        print("\nReclassified \(assignedCount) videos. \(unassigned) unassigned.")

        let updatedTopics = try store.listTopics()
        print("\nTopics:")
        for topic in updatedTopics {
            let old = topics.first { $0.id == topic.id }
            let delta = topic.videoCount - (old?.videoCount ?? 0)
            let deltaStr = delta == 0 ? "" : delta > 0 ? " (+\(delta))" : " (\(delta))"
            print("  [\(String(format: "%2d", topic.id))] \(String(format: "%4d", topic.videoCount)) videos\(deltaStr)  \(topic.name)")
        }

        print("\nRun 'generate-subtopics --all' to regenerate subtopics.")
    }
}

// MARK: - Generate Subtopics

struct GenerateSubtopics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-subtopics",
        abstract: "Discover and classify subtopics within each topic using Claude AI."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .long, help: "Process a single topic by ID.")
    var topic: Int64?

    @Flag(name: .long, help: "Process all top-level topics.")
    var all = false

    @Option(name: .long, help: "Anthropic API key.")
    var apiKey: String?

    func run() async throws {
        guard all || topic != nil else {
            print("Specify --all or --topic <id>.")
            return
        }

        let client: ClaudeClient
        if let apiKey { client = ClaudeClient(apiKey: apiKey) } else { client = try ClaudeClient() }
        let store = try TopicStore(path: db)
        let suggester = TopicSuggester(client: client)

        let topicsToProcess: [TopicSummary]
        if let topicId = topic {
            let allTopics = try store.listTopics()
            guard let t = allTopics.first(where: { $0.id == topicId }) else {
                print("Topic \(topicId) not found.")
                return
            }
            topicsToProcess = [t]
        } else {
            topicsToProcess = try store.listTopics()
        }

        print("Generating subtopics for \(topicsToProcess.count) topics...\n")

        for (index, topicSummary) in topicsToProcess.enumerated() {
            print("[\(index + 1)/\(topicsToProcess.count)] \(topicSummary.name) (\(topicSummary.videoCount) videos)")

            // Fetch videos for this topic (including any existing subtopic videos)
            let videos = try store.videosForTopicIncludingSubtopics(id: topicSummary.id)
            guard videos.count >= 3 else {
                print("  Skipping — too few videos (\(videos.count))")
                continue
            }

            let videoItems = videos.map { v in
                VideoItem(sourceIndex: v.sourceIndex, title: v.title, videoUrl: v.videoUrl,
                          videoId: v.videoId, channelName: v.channelName, metadataText: nil, unavailableKind: "none")
            }

            // Discover and classify subtopics
            let subtopics = try await suggester.discoverAndClassifySubtopics(
                topicName: topicSummary.name,
                videos: videoItems
            )

            // Delete existing subtopics (idempotent re-runs)
            try store.deleteSubtopics(parentId: topicSummary.id)

            // Create subtopics and reassign videos
            for sub in subtopics {
                let subId = try store.createSubtopic(name: sub.name, parentId: topicSummary.id)
                for vid in sub.videoIds {
                    try store.assignVideo(videoId: vid, toTopic: subId)
                }
                print("  \(String(format: "%4d", sub.videoIds.count))  \(sub.name)")
            }

            // Polite delay between topics
            if index < topicsToProcess.count - 1 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        print("\nDone. Subtopics generated successfully.")
    }
}

// MARK: - SubTopics (Preview)

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
