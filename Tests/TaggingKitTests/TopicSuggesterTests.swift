import Foundation
import Testing
@testable import TaggingKit

private actor MockClaudeClient: ClaudeCompleting {
    private var responses: [Result<String, Error>]
    private(set) var prompts: [String] = []

    init(responses: [Result<String, Error>]) {
        self.responses = responses
    }

    func complete(
        prompt: String,
        system: String?,
        model: ClaudeClient.Model,
        maxTokens: Int
    ) async throws -> String {
        prompts.append(prompt)
        guard !responses.isEmpty else {
            throw TopicSuggesterError.invalidJSON("No mock response configured")
        }
        let result = responses.removeFirst()
        return try result.get()
    }

    func recordedPrompts() -> [String] {
        prompts
    }
}

private final class ProgressRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func makeSuggestionVideos(count: Int = 4) -> [VideoItem] {
    [
        VideoItem(sourceIndex: 0, title: "Build a keyboard", videoUrl: nil, videoId: "vid-0", channelName: "Keyboards", metadataText: nil, unavailableKind: "none"),
        VideoItem(sourceIndex: 1, title: "Switch review", videoUrl: nil, videoId: "vid-1", channelName: "Keyboards", metadataText: nil, unavailableKind: "none"),
        VideoItem(sourceIndex: 2, title: "Home Assistant setup", videoUrl: nil, videoId: "vid-2", channelName: "Automation", metadataText: nil, unavailableKind: "none"),
        VideoItem(sourceIndex: 3, title: "ESP32 basics", videoUrl: nil, videoId: "vid-3", channelName: "Embedded", metadataText: nil, unavailableKind: "none")
    ].prefix(count).map { $0 }
}

@Suite("TopicSuggester")
struct TopicSuggesterTests {
    @Test("discoverTopics parses fenced JSON topic arrays")
    func discoverTopicsParsesFencedJson() async throws {
        let mock = MockClaudeClient(responses: [.success("```json\n[\"Mechanical Keyboards\", \"Home Automation\", \"Other\"]\n```")])
        let suggester = TopicSuggester(client: mock)

        let result = try await suggester.discoverTopics(videos: makeSuggestionVideos(), targetTopicCount: 3)

        #expect(result.topics == ["Mechanical Keyboards", "Home Automation", "Other"])
        let prompts = await mock.recordedPrompts()
        let prompt = try #require(prompts.first)
        #expect(prompt.localizedStandardContains("Keyboards (2 videos)"))
        #expect(prompt.localizedStandardContains("suggest exactly 3 topic categories"))
    }

    @Test("classifyVideos parses numeric and string topic identifiers across batches")
    func classifyVideosAcrossBatches() async throws {
        let mock = MockClaudeClient(responses: [
            .success("{\"0\": 2, \"1\": \"1\"}"),
            .success("Here you go:\n{\"2\": 2, \"3\": 1}\n")
        ])
        let suggester = TopicSuggester(client: mock)
        let topics = ["Keyboards", "Automation"]

        let progress = ProgressRecorder<(Int, Int)>()
        let assignments = try await suggester.classifyVideos(
            videos: makeSuggestionVideos(),
            topics: topics,
            batchSize: 2
        ) { batch, total in
            progress.append((batch, total))
        }

        let recordedProgress = progress.snapshot()
        #expect(recordedProgress.map { "\($0.0)/\($0.1)" } == ["1/2", "2/2"])
        #expect(assignments.map(\.videoIndex) == [0, 1, 2, 3])
        #expect(assignments.map(\.topic) == ["Automation", "Keyboards", "Automation", "Keyboards"])
    }

    @Test("renameSuggestion trims quotes and whitespace")
    func renameSuggestionTrimsResponse() async throws {
        let mock = MockClaudeClient(responses: [.success("  \"Smart Home\" \n")])
        let suggester = TopicSuggester(client: mock)

        let name = try await suggester.renameSuggestion(
            currentName: "Home Tech",
            sampleTitles: ["Home Assistant setup", "Zigbee switches"]
        )

        #expect(name == "Smart Home")
    }

    @Test("suggestAndClassify returns unassigned count when a batch fails")
    func suggestAndClassifyCountsUnassignedWhenClassificationFails() async throws {
        enum MockFailure: Error { case failed }

        let mock = MockClaudeClient(responses: [
            .success("[\"Keyboards\", \"Automation\"]"),
            .failure(MockFailure.failed)
        ])
        let suggester = TopicSuggester(client: mock)

        let progress = ProgressRecorder<String>()
        let result = try await suggester.suggestAndClassify(
            videos: makeSuggestionVideos(count: 2),
            targetTopicCount: 2
        ) { status in
            progress.append(status)
        }

        let recordedProgress = progress.snapshot()
        #expect(result.topics == ["Keyboards", "Automation"])
        #expect(result.assignments.isEmpty)
        #expect(result.unassignedCount == 2)
        #expect(recordedProgress.count >= 2)
        #expect(recordedProgress[0].localizedStandardContains("Discovering topics"))
        #expect(recordedProgress[1].localizedStandardContains("Found 2 topics"))
    }
}
