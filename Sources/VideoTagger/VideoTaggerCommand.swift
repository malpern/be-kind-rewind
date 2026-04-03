import ArgumentParser
import Foundation
import TaggingKit

protocol VideoTaggerYouTubeServing: Sendable {
    func fetchAllVideoMetadata(
        ids: [String],
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [VideoMetadata]

    func fetchChannelDetails(
        channelIds: [String],
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [ChannelRecord]

    func downloadChannelIcon(url: URL) async throws -> Data
}

extension YouTubeClient: VideoTaggerYouTubeServing {}

private func makeYouTubeClient(apiKey: String?) throws -> any VideoTaggerYouTubeServing {
    if let apiKey {
        return YouTubeClient(apiKey: apiKey)
    }
    return try YouTubeClient()
}

struct BackfillMetadataSummary {
    let requestedVideoCount: Int
    let updatedVideoCount: Int
    let missingVideoCount: Int
    let channelStubCount: Int
    let quotaUnitsUsed: Int
}

struct EnrichChannelsSummary {
    let backfilledVideoCount: Int
    let updatedChannelCount: Int
    let cachedIconCount: Int
    let quotaUnitsUsed: Int
}

@main
struct VideoTaggerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video-tagger",
        abstract: "Organize YouTube videos into topics using Claude AI.",
        version: "0.2.0",
        subcommands: [Suggest.self, Reclassify.self, ReclassifyAll.self, SubTopics.self, TopicsList.self, Preview.self, SplitTopic.self, MergeTopics.self, RenameTopic.self, DeleteTopic.self, Status.self, BackfillMetadata.self, EnrichChannels.self, GenerateSubtopics.self, ImportPlaylists.self, VerifyPlaylistMembership.self, VerifyAllPlaylistMemberships.self, OAuthStatus.self, OAuthAuthURL.self, OAuthExchange.self, OAuthRefresh.self]
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

// MARK: - Playlists

struct ImportPlaylists: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-playlists",
        abstract: "Import playlist identities from a youtube-cli playlists.json artifact."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .shortAndLong, help: "Path to playlists.json.")
    var json: String

    func run() throws {
        let store = try TopicStore(path: db)
        let data = try Data(contentsOf: URL(fileURLWithPath: json))
        let payload = try JSONDecoder().decode(PlaylistArtifact.self, from: data)
        let fetchedAt = payload.fetchedAt ?? ISO8601DateFormatter().string(from: Date())

        var imported = 0
        for playlist in payload.playlists where playlist.playlistId != nil {
            try store.upsertPlaylist(PlaylistRecord(
                playlistId: playlist.playlistId!,
                title: playlist.title,
                visibility: playlist.visibility,
                videoCount: playlist.videoCount,
                source: json,
                fetchedAt: fetchedAt
            ))
            imported += 1
        }

        print("Imported \(imported) playlists from \(json)")
    }
}

struct VerifyPlaylistMembership: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-playlist",
        abstract: "Verify playlist membership for videos already in the DB using the YouTube API."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .long, help: "Playlist ID to verify.")
    var playlistId: String

    @Option(name: .long, help: "Playlist title to store if missing.")
    var title: String?

    func run() async throws {
        let store = try TopicStore(path: db)
        let oauth = try? YouTubeOAuthService(config: YouTubeOAuthClientConfig.load())

        do {
            let count = try await verifyPlaylistMemberships(
                store: store,
                oauth: oauth,
                playlistId: playlistId,
                title: title
            )
            print("Verified \(count) matching videos for playlist \(playlistId)")
        } catch let error as YouTubeError {
            print(error.localizedDescription)
            if case .apiError(let code, _) = error, code == 404 {
                print("This usually means the playlist is private and the current auth mode cannot read it.")
                print("Set YOUTUBE_ACCESS_TOKEN or GOOGLE_OAUTH_ACCESS_TOKEN to an OAuth access token with YouTube read scope, then re-run.")
            }
            throw ExitCode.failure
        }
    }
}

struct VerifyAllPlaylistMemberships: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-all-playlists",
        abstract: "Verify playlist membership for all known playlists in the DB using the YouTube API."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    func run() async throws {
        let store = try TopicStore(path: db)
        let oauth = try? YouTubeOAuthService(config: YouTubeOAuthClientConfig.load())
        let playlists = try store.knownPlaylists()

        var verified = 0
        var failed = 0
        var matchedVideos = 0

        for playlist in playlists {
            do {
                let count = try await verifyPlaylistMemberships(
                    store: store,
                    oauth: oauth,
                    playlistId: playlist.playlistId,
                    title: playlist.title
                )
                verified += 1
                matchedVideos += count
                print("Verified \(playlist.title): \(count) matching videos")
            } catch {
                failed += 1
                print("Failed \(playlist.title): \(error.localizedDescription)")
            }
        }

        print("Verified \(verified) playlists, failed \(failed), matched \(matchedVideos) videos")
        if failed > 0 {
            throw ExitCode.failure
        }
    }
}

private func verifyPlaylistMemberships(
    store: TopicStore,
    oauth: YouTubeOAuthService?,
    playlistId: String,
    title: String?
) async throws -> Int {
    try await verifyPlaylistMemberships(
        store: store,
        playlistId: playlistId,
        title: title
    ) { requestedPlaylistId in
        try await fetchPlaylistItemsWithRetry(oauth: oauth, playlistId: requestedPlaylistId)
    }
}

func verifyPlaylistMemberships(
    store: TopicStore,
    playlistId: String,
    title: String?,
    verifiedAt: String = ISO8601DateFormatter().string(from: Date()),
    fetchItems: @Sendable (String) async throws -> [PlaylistVideoItem]
) async throws -> Int {
    let dbVideoIds = Set(try store.allVideoIds())
    let items = try await fetchItems(playlistId)
    let memberships = items
        .filter { dbVideoIds.contains($0.videoId) }
        .map {
            PlaylistMembershipRecord(
                playlistId: playlistId,
                videoId: $0.videoId,
                position: $0.position,
                verifiedAt: verifiedAt
            )
        }

    if let title {
        try store.upsertPlaylist(PlaylistRecord(
            playlistId: playlistId,
            title: title,
            source: "verify-playlist",
            fetchedAt: verifiedAt
        ))
    }

    try store.replacePlaylistMemberships(playlistId: playlistId, memberships: memberships)
    return memberships.count
}

private func fetchPlaylistItemsWithRetry(
    oauth: YouTubeOAuthService?,
    playlistId: String
) async throws -> [PlaylistVideoItem] {
    _ = try await oauth?.refreshIfNeeded()
    do {
        let client = try YouTubeClient()
        return try await client.fetchPlaylistItems(playlistId: playlistId)
    } catch let error as YouTubeError {
        if case .apiError(let code, _) = error, code == 401 {
            _ = try await oauth?.refreshIfNeeded(force: true)
            let client = try YouTubeClient()
            return try await client.fetchPlaylistItems(playlistId: playlistId)
        }
        throw error
    }
}

struct OAuthStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oauth-status",
        abstract: "Show YouTube OAuth configuration and token status."
    )

    func run() throws {
        let configStatus: String
        if let _ = try? YouTubeOAuthClientConfig.load() {
            configStatus = "present"
        } else {
            configStatus = "missing"
        }

        let tokens = YouTubeOAuthTokenStore().load()
        print("OAuth client config: \(configStatus)")
        if let tokens {
            print("Stored access token: present")
            print("Stored refresh token: \(tokens.refreshToken == nil ? "missing" : "present")")
            if let expiresAt = tokens.expiresAt {
                print("Access token expires at: \(ISO8601DateFormatter().string(from: expiresAt))")
                print("Expired: \(tokens.isExpired ? "yes" : "no")")
            } else {
                print("Access token expiry: unknown")
            }
        } else {
            print("Stored OAuth tokens: missing")
        }
    }
}

struct OAuthAuthURL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oauth-auth-url",
        abstract: "Print the Google OAuth authorization URL."
    )

    @Option(name: .long, help: "Redirect URI registered in Google Cloud.")
    var redirectURI: String = "http://127.0.0.1:8765/oauth/callback"

    func run() throws {
        let service = try YouTubeOAuthService(config: YouTubeOAuthClientConfig.load())
        print(service.authorizationURL(redirectURI: redirectURI).absoluteString)
    }
}

struct OAuthExchange: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oauth-exchange",
        abstract: "Exchange an OAuth authorization code and store tokens in Keychain."
    )

    @Option(name: .long, help: "Authorization code from the OAuth redirect.")
    var code: String

    @Option(name: .long, help: "Redirect URI registered in Google Cloud.")
    var redirectURI: String = "http://127.0.0.1:8765/oauth/callback"

    func run() async throws {
        let service = try YouTubeOAuthService(config: YouTubeOAuthClientConfig.load())
        let tokens = try await service.exchangeCode(code: code, redirectURI: redirectURI)
        print("Stored OAuth tokens.")
        if let expiresAt = tokens.expiresAt {
            print("Access token expires at: \(ISO8601DateFormatter().string(from: expiresAt))")
        }
        print("Refresh token: \(tokens.refreshToken == nil ? "missing" : "present")")
    }
}

struct OAuthRefresh: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oauth-refresh",
        abstract: "Refresh the stored YouTube OAuth access token."
    )

    func run() async throws {
        let service = try YouTubeOAuthService(config: YouTubeOAuthClientConfig.load())
        guard let tokens = try await service.refreshIfNeeded(force: true) else {
            print("No stored OAuth tokens.")
            throw ExitCode.failure
        }
        print("Refreshed access token.")
        if let expiresAt = tokens.expiresAt {
            print("Access token expires at: \(ISO8601DateFormatter().string(from: expiresAt))")
        }
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
        let youtube = try makeYouTubeClient(apiKey: apiKey)
        _ = try await backfillMetadata(
            store: store,
            youtube: youtube,
            all: all
        )
    }
}

// MARK: - Enrich Channels

struct EnrichChannels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enrich-channels",
        abstract: "Fetch full channel details and cache icons locally."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    @Option(name: .long, help: "YouTube/Google API key (or set YOUTUBE_API_KEY / GOOGLE_API_KEY env var).")
    var apiKey: String?

    @Flag(name: .long, help: "Re-fetch all channels, not just stubs missing details.")
    var force = false

    @Option(name: .long, help: "Max age in days before re-fetching (default 90).")
    var maxAgeDays: Int = 90

    func run() async throws {
        let store = try TopicStore(path: db)
        let youtube = try makeYouTubeClient(apiKey: apiKey)
        _ = try await enrichChannels(
            store: store,
            youtube: youtube,
            force: force,
            maxAgeDays: maxAgeDays
        )
    }
}

@discardableResult
func backfillMetadata(
    store: TopicStore,
    youtube: any VideoTaggerYouTubeServing,
    all: Bool,
    log: @Sendable @escaping (String) -> Void = { print($0) }
) async throws -> BackfillMetadataSummary {
    let ids: [String]
    if all {
        ids = try store.allVideoIds()
        log("Fetching metadata for all \(ids.count) videos...")
    } else {
        ids = try store.videoIdsMissingMetadata()
        if ids.isEmpty {
            log("All videos already have metadata.")
            return BackfillMetadataSummary(
                requestedVideoCount: 0,
                updatedVideoCount: 0,
                missingVideoCount: 0,
                channelStubCount: 0,
                quotaUnitsUsed: 0
            )
        }
        log("Fetching metadata for \(ids.count) videos missing metadata...")
    }

    let batchCount = (ids.count + 49) / 50
    log("Quota: \(batchCount) API calls (\(batchCount) of 10,000 daily units)")

    let metadata = try await youtube.fetchAllVideoMetadata(ids: ids) { batch, total in
        log("  Batch \(batch)/\(total)...")
    }

    var updated = 0
    var channelStubs = 0
    for item in metadata {
        try store.updateVideoMetadata(
            videoId: item.videoId,
            viewCount: item.formattedViewCount,
            publishedAt: item.formattedDate,
            duration: item.formattedDuration,
            channelIconUrl: nil
        )

        if let channelId = item.channelId {
            try store.setVideoChannelId(videoId: item.videoId, channelId: channelId)
            if try store.channelById(channelId) == nil {
                try store.upsertChannel(ChannelRecord(
                    channelId: channelId,
                    name: item.channelTitle ?? channelId,
                    channelUrl: "https://www.youtube.com/channel/\(channelId)"
                ))
                channelStubs += 1
            }
        }
        updated += 1
    }

    let missing = ids.count - updated
    log("")
    log("Updated \(updated) videos. Used \(batchCount) quota units.")
    if channelStubs > 0 {
        log("Created \(channelStubs) channel stubs. Run 'enrich-channels' for full details + cached icons.")
    }
    if missing > 0 {
        log("\(missing) videos had no YouTube data (possibly deleted/private).")
    }

    return BackfillMetadataSummary(
        requestedVideoCount: ids.count,
        updatedVideoCount: updated,
        missingVideoCount: missing,
        channelStubCount: channelStubs,
        quotaUnitsUsed: batchCount
    )
}

@discardableResult
func enrichChannels(
    store: TopicStore,
    youtube: any VideoTaggerYouTubeServing,
    force: Bool,
    maxAgeDays: Int,
    log: @Sendable @escaping (String) -> Void = { print($0) }
) async throws -> EnrichChannelsSummary {
    var quotaUsed = 0
    var backfilled = 0

    let missingChannelIds = try store.videoIdsMissingChannelId()
    if !missingChannelIds.isEmpty {
        let batchCount = (missingChannelIds.count + 49) / 50
        log("Step 1: Backfilling channel_id for \(missingChannelIds.count) videos (\(batchCount) API calls = \(batchCount) quota units)")
        let metadata = try await youtube.fetchAllVideoMetadata(ids: missingChannelIds) { batch, total in
            log("  videos.list batch \(batch)/\(total)...")
        }
        quotaUsed += batchCount
        for item in metadata {
            if let channelId = item.channelId {
                try store.setVideoChannelId(videoId: item.videoId, channelId: channelId)
                if try store.channelById(channelId) == nil {
                    try store.upsertChannel(ChannelRecord(
                        channelId: channelId,
                        name: item.channelTitle ?? channelId,
                        channelUrl: "https://www.youtube.com/channel/\(channelId)"
                    ))
                }
                backfilled += 1
            }
        }
        log("  Backfilled \(backfilled) videos.\n")
    } else {
        log("Step 1: All videos already have channel_id. Skipping. (0 quota units)")
    }

    let allChannelIds = try store.allChannelIds()
    let channelsToEnrich: [String]
    if force {
        channelsToEnrich = allChannelIds
    } else {
        channelsToEnrich = try allChannelIds.filter { channelId in
            guard let channel = try store.channelById(channelId) else { return true }
            guard let fetchedAt = channel.fetchedAt else { return true }
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: fetchedAt) else { return true }
            return Date().timeIntervalSince(date) > Double(maxAgeDays * 86400)
        }
    }

    var updatedChannels = 0
    if channelsToEnrich.isEmpty {
        log("Step 2: All \(allChannelIds.count) channels up to date. (0 quota units)")
    } else {
        let batchCount = (channelsToEnrich.count + 49) / 50
        log("Step 2: Enriching \(channelsToEnrich.count) of \(allChannelIds.count) channels (\(batchCount) API calls = \(batchCount) quota units)")
        let channelRecords = try await youtube.fetchChannelDetails(channelIds: channelsToEnrich) { batch, total in
            log("  channels.list batch \(batch)/\(total)...")
        }
        quotaUsed += batchCount

        for record in channelRecords {
            try store.upsertChannel(record)
        }
        updatedChannels = channelRecords.count
        log("  Updated \(channelRecords.count) channel records.\n")
    }

    let channelsNeedingIcons = try allChannelIds.compactMap { channelId -> ChannelRecord? in
        guard let channel = try store.channelById(channelId) else { return nil }
        return (channel.iconData == nil && channel.iconUrl != nil) ? channel : nil
    }

    var iconCount = 0
    if !channelsNeedingIcons.isEmpty {
        log("Step 3: Downloading \(channelsNeedingIcons.count) channel icons from CDN (0 quota units — CDN is free)")
        for channel in channelsNeedingIcons {
            guard let urlString = channel.iconUrl, let url = URL(string: urlString) else { continue }
            do {
                let data = try await youtube.downloadChannelIcon(url: url)
                try store.updateChannelIcon(channelId: channel.channelId, iconData: data)
                iconCount += 1
                if iconCount % 50 == 0 {
                    log("  Downloaded \(iconCount)/\(channelsNeedingIcons.count) icons...")
                }
            } catch {
                log("  ⚠ Failed: \(channel.name)")
            }
        }
        log("  Cached \(iconCount) icons locally.\n")
    } else {
        log("Step 3: All channel icons already cached. (0 quota units)")
    }

    log("Done. Used \(quotaUsed) of 10,000 daily quota units.")
    log("Channel data is ready for creator circles.")

    return EnrichChannelsSummary(
        backfilledVideoCount: backfilled,
        updatedChannelCount: updatedChannels,
        cachedIconCount: iconCount,
        quotaUnitsUsed: quotaUsed
    )
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

private struct PlaylistArtifact: Decodable {
    let fetchedAt: String?
    let playlists: [PlaylistArtifactItem]
}

private struct PlaylistArtifactItem: Decodable {
    let playlistId: String?
    let title: String
    let visibility: String?
    let videoCount: Int?
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
