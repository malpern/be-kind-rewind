import Foundation

/// Three-step topic suggestion: discover topics from channels, then classify videos.
public actor TopicSuggester {
    private let client: ClaudeClient

    public init(client: ClaudeClient) {
        self.client = client
    }

    public struct TopicList: Sendable {
        public let topics: [String]
    }

    public struct ClassifiedVideo: Sendable {
        public let videoIndex: Int
        public let topic: String
    }

    public struct SuggestionResult: Sendable {
        public let topics: [String]
        public let assignments: [ClassifiedVideo]
        public let unassignedCount: Int
    }

    // MARK: - Step 1: Discover topics from channels

    /// Analyze channel names to discover the major topics in the collection.
    /// Uses Haiku for speed. Sends only channels with 2+ videos to keep it focused.
    public func discoverTopics(
        videos: [VideoItem],
        targetTopicCount: Int = 15
    ) async throws -> TopicList {
        // Build channel → count + sample titles map
        var channelInfo: [String: (count: Int, sampleTitles: [String])] = [:]
        for video in videos {
            let ch = video.channelName ?? "Unknown"
            var info = channelInfo[ch, default: (count: 0, sampleTitles: [])]
            info.count += 1
            if info.sampleTitles.count < 3 {
                if let title = video.title {
                    info.sampleTitles.append(title)
                }
            }
            channelInfo[ch] = info
        }

        // Include channels with 2+ videos, plus a sample of single-video channels
        let significantChannels = channelInfo
            .filter { $0.value.count >= 2 }
            .sorted { $0.value.count > $1.value.count }

        let channelList = significantChannels.map { ch, info in
            let titles = info.sampleTitles.prefix(2).joined(separator: "; ")
            return "\(ch) (\(info.count) videos) — e.g. \(titles)"
        }.joined(separator: "\n")

        let prompt = """
        I have a YouTube Watch Later collection with \(videos.count) videos from \(channelInfo.count) channels.
        Here are the channels with 2+ videos and sample titles:

        \(channelList)

        Based on these channels and their content, suggest exactly \(targetTopicCount) topic categories that would organize this collection well.

        Requirements:
        - Topics should be specific enough to be useful ("Mechanical Keyboards" not "Technology")
        - Topics should cover the breadth of the collection
        - Each topic name should be 2-4 words
        - Include an "Other" or "Miscellaneous" topic for outliers

        Return ONLY a JSON array of topic name strings, nothing else:
        ["Topic One", "Topic Two", ...]
        """

        let response = try await client.complete(
            prompt: prompt,
            system: "You are a video librarian organizing a personal YouTube collection. Return only valid JSON.",
            model: .haiku,
            maxTokens: 1024
        )

        let topicNames = try parseStringArray(response)
        return TopicList(topics: topicNames)
    }

    // MARK: - Step 2: Classify videos against fixed topic list

    /// Assign each video to exactly one topic from the fixed list.
    public func classifyVideos(
        videos: [VideoItem],
        topics: [String],
        batchSize: Int = 200,
        model: ClaudeClient.Model = .haiku,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [ClassifiedVideo] {
        let topicList = topics.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")

        let batches = stride(from: 0, to: videos.count, by: batchSize).map { start in
            let end = min(start + batchSize, videos.count)
            return (offset: start, items: Array(videos[start..<end]))
        }

        var allAssignments: [ClassifiedVideo] = []

        for (batchIdx, batch) in batches.enumerated() {
            onProgress?(batchIdx + 1, batches.count)

            // Polite delay between batches
            if batchIdx > 0 {
                try? await Task.sleep(for: .milliseconds(200))
            }

            let titleList = batch.items.enumerated().map { i, v in
                let channel = v.channelName.map { " [\($0)]" } ?? ""
                return "\(batch.offset + i). \(v.title ?? "Untitled")\(channel)"
            }.joined(separator: "\n")

            let prompt = """
            Assign each video to exactly ONE of these topics:

            \(topicList)

            Videos:
            \(titleList)

            Return ONLY a JSON object mapping video index to topic number:
            {"0": 3, "5": 1, "12": 7, ...}

            Every video must be assigned. Use the topic number, not the name.
            """

            do {
                let response = try await client.complete(
                    prompt: prompt,
                    system: "You are classifying videos into predefined topics. Return only valid JSON. Every video index must appear in the output.",
                    model: model,
                    maxTokens: 4096
                )

                let assignments = try parseClassificationResponse(response, topics: topics, batchOffset: batch.offset)
                allAssignments.append(contentsOf: assignments)
            } catch {
                print("  ⚠ Batch \(batchIdx + 1) failed: \(error.localizedDescription). Skipping.")
            }
        }

        return allAssignments
    }

    // MARK: - Step 3: Split a topic into sub-topics (uses Sonnet)

    public func splitTopic(
        topicName: String,
        videos: [VideoItem],
        videoIndices: [Int],
        targetSubTopics: Int = 3
    ) async throws -> [(name: String, videoIndices: [Int])] {
        // Step 1: Ask Sonnet to suggest sub-topic names from a sample
        let sampleTitles = videos.prefix(100).enumerated().map { i, v in
            let channel = v.channelName.map { " [\($0)]" } ?? ""
            return "\(v.title ?? "Untitled")\(channel)"
        }.joined(separator: "\n")

        let discoverPrompt = """
        This topic "\(topicName)" has \(videos.count) videos. Here's a sample:

        \(sampleTitles)

        Suggest exactly \(targetSubTopics) sub-topic names to split this into.
        Return ONLY a JSON array of strings: ["Sub-Topic A", "Sub-Topic B", ...]
        """

        let namesResponse = try await client.complete(
            prompt: discoverPrompt,
            system: "You are a video librarian splitting a broad topic into specific sub-categories. Return only valid JSON.",
            model: .sonnet,
            maxTokens: 512
        )

        let subTopicNames = try parseStringArray(namesResponse)

        // Step 2: Classify all videos against the fixed sub-topic list using Haiku
        let classified = try await classifyVideos(
            videos: videos,
            topics: subTopicNames,
            batchSize: 200
        )

        // Group by sub-topic
        var groups: [String: [Int]] = [:]
        for c in classified {
            groups[c.topic, default: []].append(videoIndices[c.videoIndex])
        }

        return subTopicNames.compactMap { name in
            guard let indices = groups[name], !indices.isEmpty else { return nil }
            return (name: name, videoIndices: indices)
        }
    }

    // MARK: - Discover subtopics (auto count, Sonnet)

    /// Discover subtopics for a topic. Sonnet decides the natural number of subtopics.
    /// Returns subtopic names and video assignments (by videoId).
    public func discoverAndClassifySubtopics(
        topicName: String,
        videos: [VideoItem]
    ) async throws -> [(name: String, videoIds: [String])] {
        // Step 1: Sonnet discovers subtopic names (auto count)
        let sampleTitles = videos.prefix(200).map { v in
            let channel = v.channelName.map { " [\($0)]" } ?? ""
            return "\(v.title ?? "Untitled")\(channel)"
        }.joined(separator: "\n")

        let discoverPrompt = """
        This YouTube topic "\(topicName)" has \(videos.count) videos. Here's a sample:

        \(sampleTitles)

        Analyze these videos and suggest a natural number of sub-categories (typically 3-8) that would meaningfully organize them. Each sub-category should have a short descriptive name (2-5 words).

        Return ONLY a JSON array of strings: ["Sub-Category A", "Sub-Category B", ...]
        """

        let namesResponse = try await client.complete(
            prompt: discoverPrompt,
            system: "You are a video librarian organizing a topic into sub-categories. Choose the number of sub-categories that makes sense for this content — don't force categories where none exist. Return only valid JSON.",
            model: .sonnet,
            maxTokens: 512
        )

        let subtopicNames = try parseStringArray(namesResponse)

        // Step 2: Classify all videos against subtopic list using Haiku
        let classified = try await classifyVideos(
            videos: videos,
            topics: subtopicNames,
            batchSize: 200
        )

        // Group by subtopic, using videoId instead of sourceIndex
        var groups: [String: [String]] = [:]
        for c in classified {
            let vid = videos[c.videoIndex].videoId ?? ""
            guard !vid.isEmpty else { continue }
            groups[c.topic, default: []].append(vid)
        }

        return subtopicNames.compactMap { name in
            guard let ids = groups[name], !ids.isEmpty else { return nil }
            return (name: name, videoIds: ids)
        }
    }

    /// Suggest a better name for a topic. Uses Sonnet.
    public func renameSuggestion(
        currentName: String,
        sampleTitles: [String]
    ) async throws -> String {
        let titles = sampleTitles.prefix(20).joined(separator: "\n")
        let prompt = """
        This topic is named "\(currentName)" and contains videos like:

        \(titles)

        Suggest a better 2-4 word topic name. Return ONLY the name.
        """

        return try await client.complete(prompt: prompt, model: .sonnet, maxTokens: 50)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
    }

    // MARK: - Orchestration

    /// Full pipeline: discover topics, then classify all videos.
    public func suggestAndClassify(
        videos: [VideoItem],
        targetTopicCount: Int = 15,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SuggestionResult {
        onProgress?("Discovering topics from \(videos.count) videos...")
        let topicList = try await discoverTopics(videos: videos, targetTopicCount: targetTopicCount)
        onProgress?("Found \(topicList.topics.count) topics. Classifying videos...")

        let assignments = try await classifyVideos(
            videos: videos,
            topics: topicList.topics
        ) { batch, total in
            onProgress?("Classifying batch \(batch)/\(total)...")
        }

        let assignedIndices = Set(assignments.map(\.videoIndex))
        let unassigned = videos.indices.filter { !assignedIndices.contains($0) }.count

        return SuggestionResult(
            topics: topicList.topics,
            assignments: assignments,
            unassignedCount: unassigned
        )
    }

    // MARK: - Parsing

    private func parseStringArray(_ response: String) throws -> [String] {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw TopicSuggesterError.invalidJSON(response.prefix(200).description)
        }

        return try JSONDecoder().decode([String].self, from: data)
    }

    private func parseClassificationResponse(
        _ response: String,
        topics: [String],
        batchOffset: Int
    ) throws -> [ClassifiedVideo] {
        var cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract JSON object if surrounded by text
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        guard let data = cleaned.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TopicSuggesterError.invalidJSON(response.prefix(200).description)
        }

        var results: [ClassifiedVideo] = []
        for (indexStr, topicValue) in dict {
            guard let videoIndex = Int(indexStr) else { continue }

            let topicName: String
            if let topicNum = topicValue as? Int, topicNum >= 1, topicNum <= topics.count {
                topicName = topics[topicNum - 1]
            } else if let topicStr = topicValue as? String, let topicNum = Int(topicStr),
                      topicNum >= 1, topicNum <= topics.count {
                topicName = topics[topicNum - 1]
            } else {
                continue
            }

            results.append(ClassifiedVideo(videoIndex: videoIndex, topic: topicName))
        }

        return results
    }

    private func parseTopicSplitResponse(_ response: String) throws -> [(name: String, videoIndices: [Int])] {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw TopicSuggesterError.invalidJSON(response.prefix(200).description)
        }

        let parsed = try JSONDecoder().decode([SplitEntry].self, from: data)
        return parsed.map { ($0.topic, $0.indices) }
    }

    private struct SplitEntry: Decodable {
        let topic: String
        let indices: [Int]
    }
}

public enum TopicSuggesterError: LocalizedError {
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let preview):
            "Could not parse Claude's response as JSON: \(preview)"
        }
    }
}
