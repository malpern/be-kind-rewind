import Foundation
import Testing
@testable import TaggingKit

private actor MockClaudeClient: ClaudeCompleting {
    var nextResponse: String
    private(set) var lastPrompt: String?
    private(set) var lastSystem: String?
    private(set) var lastModel: ClaudeClient.Model?
    private(set) var callCount: Int = 0

    init(response: String) {
        self.nextResponse = response
    }

    func complete(
        prompt: String,
        system: String?,
        model: ClaudeClient.Model,
        maxTokens: Int
    ) async throws -> String {
        lastPrompt = prompt
        lastSystem = system
        lastModel = model
        callCount += 1
        return nextResponse
    }

    func setNextResponse(_ response: String) {
        nextResponse = response
    }
}

@Suite("CreatorThemeClassifier")
struct CreatorThemeClassifierTests {

    @Test("classifyThemes parses a well-formed Claude response into ThemeClusters")
    func parsesValidResponse() async throws {
        let response = """
        {
          "clusters": [
            {
              "label": "Switch Reviews",
              "description": "Reviews of mechanical keyboard switches",
              "video_ids": ["v1", "v2", "v3"],
              "is_series": false,
              "ordering_signal": null
            },
            {
              "label": "Day Build Vlog",
              "description": "30-day keyboard build series",
              "video_ids": ["v4", "v5", "v6"],
              "is_series": true,
              "ordering_signal": "numeric"
            }
          ]
        }
        """
        let mock = MockClaudeClient(response: response)
        let classifier = CreatorThemeClassifier(client: mock)

        let videos = [
            CreatorThemeClassifier.CreatorVideoInput(videoId: "v1", title: "Cherry MX Brown review"),
            CreatorThemeClassifier.CreatorVideoInput(videoId: "v2", title: "Gateron Yellow vs Cherry"),
            CreatorThemeClassifier.CreatorVideoInput(videoId: "v3", title: "Best linear switches 2025"),
            CreatorThemeClassifier.CreatorVideoInput(videoId: "v4", title: "Day 1: Building my keyboard"),
            CreatorThemeClassifier.CreatorVideoInput(videoId: "v5", title: "Day 2: Lubing the switches"),
            CreatorThemeClassifier.CreatorVideoInput(videoId: "v6", title: "Day 3: Filming the unboxing")
        ]

        let result = try await classifier.classifyThemes(creatorName: "Hipyo Tech", videos: videos)

        #expect(result.classifiedVideoCount == 6)
        #expect(result.themes.count == 2)

        let switchReviews = result.themes.first { $0.label == "Switch Reviews" }
        #expect(switchReviews != nil)
        #expect(switchReviews?.videoIds == ["v1", "v2", "v3"])
        #expect(switchReviews?.isSeries == false)
        #expect(switchReviews?.orderingSignal == nil)

        let dayVlog = result.themes.first { $0.label == "Day Build Vlog" }
        #expect(dayVlog != nil)
        #expect(dayVlog?.videoIds == ["v4", "v5", "v6"])
        #expect(dayVlog?.isSeries == true)
        #expect(dayVlog?.orderingSignal == .numeric)
    }

    @Test("classifyThemes filters out video IDs Claude returns that weren't in the input")
    func dropsHallucinatedVideoIds() async throws {
        let response = """
        {
          "clusters": [
            {
              "label": "Reviews",
              "description": "All reviews",
              "video_ids": ["v1", "fake-id", "v2"],
              "is_series": false,
              "ordering_signal": null
            }
          ]
        }
        """
        let mock = MockClaudeClient(response: response)
        let classifier = CreatorThemeClassifier(client: mock)

        let videos = [
            CreatorThemeClassifier.CreatorVideoInput(videoId: "v1", title: "review one"),
            CreatorThemeClassifier.CreatorVideoInput(videoId: "v2", title: "review two")
        ]

        let result = try await classifier.classifyThemes(creatorName: "Test", videos: videos)
        #expect(result.themes.count == 1)
        #expect(result.themes[0].videoIds == ["v1", "v2"]) // hallucinated ID dropped
    }

    @Test("classifyThemes throws on empty input")
    func throwsOnEmptyInput() async throws {
        let mock = MockClaudeClient(response: "{}")
        let classifier = CreatorThemeClassifier(client: mock)

        do {
            _ = try await classifier.classifyThemes(creatorName: "Empty", videos: [])
            Issue.record("Expected emptyInput error")
        } catch CreatorThemeClassifier.CreatorThemeClassifierError.emptyInput {
            // expected
        }
    }

    @Test("classifyThemes throws on malformed JSON")
    func throwsOnInvalidJSON() async throws {
        let mock = MockClaudeClient(response: "this is not json at all")
        let classifier = CreatorThemeClassifier(client: mock)

        let videos = [CreatorThemeClassifier.CreatorVideoInput(videoId: "v1", title: "t")]

        do {
            _ = try await classifier.classifyThemes(creatorName: "Test", videos: videos)
            Issue.record("Expected invalidJSON error")
        } catch CreatorThemeClassifier.CreatorThemeClassifierError.invalidJSON {
            // expected
        }
    }

    @Test("classifyThemes strips markdown code fences from Claude responses")
    func stripsCodeFences() async throws {
        let response = """
        ```json
        {
          "clusters": [
            {"label": "T", "description": "d", "video_ids": ["v1"], "is_series": false, "ordering_signal": null}
          ]
        }
        ```
        """
        let mock = MockClaudeClient(response: response)
        let classifier = CreatorThemeClassifier(client: mock)

        let videos = [CreatorThemeClassifier.CreatorVideoInput(videoId: "v1", title: "t")]
        let result = try await classifier.classifyThemes(creatorName: "Test", videos: videos)
        #expect(result.themes.count == 1)
    }

    @Test("classifyThemes caps input at maxVideos")
    func capsAtMaxVideos() async throws {
        // Build 250 videos but cap at 10. The mock response references only the first 10.
        var videoIds: [String] = []
        var videos: [CreatorThemeClassifier.CreatorVideoInput] = []
        for i in 0..<250 {
            let id = "v\(i)"
            videoIds.append(id)
            videos.append(.init(videoId: id, title: "Video \(i)"))
        }

        let firstTen = Array(videoIds.prefix(10)).map { "\"\($0)\"" }.joined(separator: ", ")
        let response = """
        {"clusters": [{"label": "All", "description": "", "video_ids": [\(firstTen)], "is_series": false, "ordering_signal": null}]}
        """
        let mock = MockClaudeClient(response: response)
        let classifier = CreatorThemeClassifier(client: mock)

        let result = try await classifier.classifyThemes(creatorName: "Test", videos: videos, maxVideos: 10)
        #expect(result.classifiedVideoCount == 10)
        #expect(result.themes[0].videoIds.count == 10)
    }

    @Test("generateAbout returns the trimmed Claude response as a paragraph")
    func generateAboutReturnsParagraph() async throws {
        let mock = MockClaudeClient(response: "  This creator makes keyboard videos.  ")
        let classifier = CreatorThemeClassifier(client: mock)

        let videos = [CreatorThemeClassifier.CreatorVideoInput(videoId: "v1", title: "Build vlog")]
        let about = try await classifier.generateAbout(creatorName: "Hipyo", videos: videos)

        #expect(about == "This creator makes keyboard videos.")
    }

    @Test("generateAbout throws on empty input")
    func generateAboutThrowsOnEmptyInput() async throws {
        let mock = MockClaudeClient(response: "anything")
        let classifier = CreatorThemeClassifier(client: mock)

        do {
            _ = try await classifier.generateAbout(creatorName: "Empty", videos: [])
            Issue.record("Expected emptyInput error")
        } catch CreatorThemeClassifier.CreatorThemeClassifierError.emptyInput {
            // expected
        }
    }
}
