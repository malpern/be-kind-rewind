import ArgumentParser
import Foundation
import Testing
@testable import TaggingKit
@testable import VideoTagger

private func withTemporaryDirectory<Result>(
    _ body: (URL) throws -> Result
) throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

private struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func runCLI(arguments: [String], environment: [String: String] = [:]) throws -> CLIResult {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let executableURL = repositoryRoot
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("debug", isDirectory: true)
        .appendingPathComponent("video-tagger", isDirectory: false)

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return CLIResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func makeVideo(id: String, index: Int, title: String, channelName: String = "Channel") -> VideoItem {
    VideoItem(
        sourceIndex: index,
        title: title,
        videoUrl: "https://youtube.com/watch?v=\(id)",
        videoId: id,
        channelName: channelName,
        metadataText: nil,
        unavailableKind: "none"
    )
}

private func makeStore(at path: String, videoCount: Int = 4) throws -> TopicStore {
    let store = try TopicStore(path: path)
    let videos = (0..<videoCount).map { index in
        makeVideo(id: "vid-\(index)", index: index, title: "Video \(index)", channelName: "Channel \(index % 2)")
    }
    try store.importVideos(videos)
    return store
}

@Suite("VideoTagger CLI")
struct VideoTaggerCommandTests {
    @Test("topics command parses database override")
    func topicsListParsesDatabaseOverride() throws {
        let command = try #require(TopicsList.parseAsRoot(["--db", "/tmp/custom.db"]) as? TopicsList)
        #expect(command.db == "/tmp/custom.db")
    }

    @Test("preview command parses topic, db, and limit")
    func previewParsesArguments() throws {
        let command = try #require(Preview.parseAsRoot(["12", "--db", "/tmp/videos.db", "--limit", "7"]) as? Preview)
        #expect(command.topicId == 12)
        #expect(command.db == "/tmp/videos.db")
        #expect(command.limit == 7)
    }

    @Test("status reports totals, topics, and pending sync actions")
    func statusReportsDatabaseSummary() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let store = try makeStore(at: dbPath, videoCount: 3)
            let topicId = try store.createTopic(name: "Keep")
            try store.assignVideo(videoId: "vid-0", toTopic: topicId)
            try store.queueCommit(action: "add_to_playlist", videoId: "vid-0", playlist: "Watch Later")
            let result = try runCLI(arguments: ["status", "--db", dbPath])

            #expect(result.status == 0)
            #expect(result.stdout.contains("Videos: 3 total, 1 assigned, 2 unassigned"))
            #expect(result.stdout.contains("Topics: 1"))
            #expect(result.stdout.contains("Pending sync: 1 actions"))
        }
    }

    @Test("topics lists topic counts in sorted order")
    func topicsListPrintsSortedCounts() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let store = try makeStore(at: dbPath, videoCount: 5)
            let smaller = try store.createTopic(name: "Smaller")
            let larger = try store.createTopic(name: "Larger")
            try store.assignVideos(indices: [0, 1], toTopic: smaller)
            try store.assignVideos(indices: [2, 3, 4], toTopic: larger)
            let result = try runCLI(arguments: ["topics", "--db", dbPath])

            let lines = result.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            let first = try #require(lines.first)
            let second = try #require(lines.dropFirst().first)
            #expect(result.status == 0)
            #expect(first.contains("Larger"))
            #expect(first.contains("3"))
            #expect(second.contains("Smaller"))
        }
    }

    @Test("topics lists unassigned count when videos remain unclassified")
    func topicsListPrintsUnassignedCount() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let store = try makeStore(at: dbPath, videoCount: 4)
            let topicId = try store.createTopic(name: "Assigned")
            try store.assignVideo(videoId: "vid-0", toTopic: topicId)

            let result = try runCLI(arguments: ["topics", "--db", dbPath])

            #expect(result.status == 0)
            #expect(result.stdout.contains("Assigned"))
            #expect(result.stdout.contains("3 unassigned"))
        }
    }

    @Test("preview shows titles, channels, and remaining count")
    func previewPrintsTopicContents() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let store = try TopicStore(path: dbPath)
            let videos = [
                makeVideo(id: "vid-0", index: 0, title: "First", channelName: "Alpha"),
                makeVideo(id: "vid-1", index: 1, title: "Second", channelName: "Beta"),
                makeVideo(id: "vid-2", index: 2, title: "Third", channelName: "Gamma")
            ]
            try store.importVideos(videos)
            let topicId = try store.createTopic(name: "Featured")
            try store.assignVideos(indices: [0, 1, 2], toTopic: topicId)
            let result = try runCLI(arguments: ["preview", String(topicId), "--db", dbPath, "--limit", "2"])

            #expect(result.status == 0)
            #expect(result.stdout.contains("Featured (3 videos):"))
            #expect(result.stdout.contains("First [Alpha]"))
            #expect(result.stdout.contains("Second [Beta]"))
            #expect(result.stdout.contains("... and 1 more"))
        }
    }

    @Test("preview reports missing topics without failing")
    func previewPrintsMissingTopicMessage() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            _ = try makeStore(at: dbPath, videoCount: 2)

            let result = try runCLI(arguments: ["preview", "999", "--db", dbPath])

            #expect(result.status == 0)
            #expect(result.stdout.contains("Topic 999 not found."))
        }
    }

    @Test("merge with fewer than two topic ids prints guidance")
    func mergeRequiresAtLeastTwoTopicIds() throws {
        let result = try runCLI(arguments: ["merge", "42", "--db", "unused.db"])

        #expect(result.status == 0)
        #expect(result.stdout.contains("Need at least 2 topic IDs."))
    }

    @Test("merge combines source topics into the first topic")
    func mergeMovesVideosIntoFirstTopic() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let store = try makeStore(at: dbPath, videoCount: 4)
            let keepId = try store.createTopic(name: "Keep")
            let mergeId = try store.createTopic(name: "Merge")
            try store.assignVideos(indices: [0, 1], toTopic: keepId)
            try store.assignVideos(indices: [2, 3], toTopic: mergeId)

            let result = try runCLI(arguments: ["merge", String(keepId), String(mergeId), "--db", dbPath])

            let topics = try store.listTopics()
            #expect(result.status == 0)
            #expect(result.stdout.contains("Merged into \"Keep\" (4 videos)"))
            #expect(topics.count == 1)
            #expect(topics.first?.name == "Keep")
            #expect(topics.first?.videoCount == 4)
        }
    }

    @Test("rename updates stored topic name")
    func renameUpdatesTopic() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let store = try makeStore(at: dbPath)
            let topicId = try store.createTopic(name: "Old Name")
            let result = try runCLI(arguments: ["rename", String(topicId), "New Name", "--db", dbPath])

            let updated = try #require(try store.listTopics().first)
            #expect(result.status == 0)
            #expect(updated.name == "New Name")
            #expect(result.stdout.contains("Renamed to \"New Name\""))
        }
    }

    @Test("delete unassigns videos from the topic")
    func deleteUnassignsVideos() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let store = try makeStore(at: dbPath, videoCount: 3)
            let topicId = try store.createTopic(name: "Disposable")
            try store.assignVideos(indices: [0, 1], toTopic: topicId)
            let result = try runCLI(arguments: ["delete", String(topicId), "--db", dbPath])

            #expect(result.status == 0)
            #expect(try store.unassignedCount() == 3)
            #expect(result.stdout.contains("Deleted. Videos are now unassigned."))
        }
    }

    @Test("import-playlists persists valid playlist rows and skips missing ids")
    func importPlaylistsPersistsArtifact() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let jsonPath = directory.appendingPathComponent("playlists.json")

            let payload = """
            {
              "fetchedAt": "2026-04-03T12:00:00Z",
              "playlists": [
                {
                  "playlistId": "PL123",
                  "title": "Useful Videos",
                  "visibility": "public",
                  "videoCount": 12
                },
                {
                  "title": "Missing ID",
                  "visibility": "private",
                  "videoCount": 8
                }
              ]
            }
            """
            try payload.write(to: jsonPath, atomically: true, encoding: .utf8)
            let result = try runCLI(arguments: ["import-playlists", "--db", dbPath, "--json", jsonPath.path])

            let store = try TopicStore(path: dbPath)
            let playlists = try store.knownPlaylists()
            #expect(result.status == 0)
            #expect(playlists.count == 1)
            #expect(playlists.first?.playlistId == "PL123")
            #expect(playlists.first?.title == "Useful Videos")
            #expect(result.stdout.contains("Imported 1 playlists"))
        }
    }

    @Test("import-playlists fails for invalid JSON input")
    func importPlaylistsFailsForInvalidJson() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let jsonPath = directory.appendingPathComponent("playlists.json")
            try "{not valid json".write(to: jsonPath, atomically: true, encoding: .utf8)

            let result = try runCLI(arguments: ["import-playlists", "--db", dbPath, "--json", jsonPath.path])

            #expect(result.status != 0)
            #expect(result.stderr.contains("The given data was not valid JSON"))
        }
    }

    @Test("verify-all-playlists succeeds immediately when no playlists are known")
    func verifyAllPlaylistsHandlesEmptyDatabase() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("video-tagger.db").path
            let _ = try TopicStore(path: dbPath)

            let result = try runCLI(arguments: ["verify-all-playlists", "--db", dbPath])

            #expect(result.status == 0)
            #expect(result.stdout.contains("Verified 0 playlists, failed 0, matched 0 videos"))
        }
    }

    @Test("oauth-auth-url uses environment client config and redirect URI")
    func oauthAuthURLPrintsGoogleAuthorizationURL() throws {
        let result = try runCLI(
            arguments: ["oauth-auth-url", "--redirect-uri", "http://127.0.0.1:9999/callback"],
            environment: [
                "GOOGLE_OAUTH_CLIENT_ID": "client-id-123",
                "GOOGLE_OAUTH_CLIENT_SECRET": "client-secret-456"
            ]
        )

        #expect(result.status == 0)
        #expect(result.stdout.contains("https://accounts.google.com/o/oauth2/v2/auth?"))
        #expect(result.stdout.contains("client_id=client-id-123"))
        #expect(result.stdout.contains("redirect_uri=http://127.0.0.1:9999/callback"))
        #expect(result.stdout.contains("code_challenge_method=S256"))
    }

    @Test("generate-subtopics requires a selector before running AI work")
    func generateSubtopicsRequiresTopicOrAll() throws {
        let result = try runCLI(arguments: ["generate-subtopics", "--db", "video-tagger.db"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("Specify --all or --topic <id>."))
    }
}
