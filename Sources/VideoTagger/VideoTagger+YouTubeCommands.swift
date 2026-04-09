import ArgumentParser
import Foundation
import TaggingKit

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

struct SyncPendingActions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-pending",
        abstract: "Push queued YouTube playlist actions to the authenticated account."
    )

    @Option(name: .shortAndLong, help: "Path to the SQLite database.")
    var db: String = "video-tagger.db"

    func run() async throws {
        let store = try TopicStore(path: db)
        let recovered = try store.recoverStaleInProgressCommits()
        if recovered > 0 {
            print("Recovered \(recovered) interrupted sync actions")
        }
        let pending = try store.pendingSyncPlan()
        guard !pending.isEmpty else {
            print("No pending sync actions")
            return
        }

        let client = try YouTubeClient()
        let apiActions = try store.pendingSyncPlan(executor: .api)
        if !apiActions.isEmpty {
            try store.markInProgress(ids: apiActions.map(\.id))
            let apiResult = await YouTubeSyncService(client: client).execute(actions: apiActions)
            try store.markSynced(ids: apiResult.syncedActionIDs)
            try store.markDeferred(ids: apiResult.deferredActionIDs, error: "Waiting for browser executor")
            try store.moveToExecutor(
                ids: apiResult.browserFallbackActionIDs,
                executor: .browser,
                state: .deferred,
                error: "API quota exhausted. Waiting for browser executor fallback."
            )
            try store.markFailed(apiResult.failures, retryAfter: 300)
            print("Synced \(apiResult.syncedActionIDs.count) API actions")
        }

        let browserActions = try store.pendingSyncPlan(executor: .browser)
        if !browserActions.isEmpty {
            try store.markInProgress(ids: browserActions.map(\.id))
            let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let browserResult = try await BrowserSyncService(repoRoot: repoRoot).execute(actions: browserActions)
            try store.markSynced(ids: browserResult.syncedActionIDs)
            try store.markFailed(browserResult.failures, retryAfter: 300)
            print("Synced \(browserResult.syncedActionIDs.count) browser actions")
            if !browserResult.failures.isEmpty {
                for failure in browserResult.failures {
                    print("Failed browser action \(failure.id): \(failure.message)")
                }
                throw ExitCode.failure
            }
        }
    }
}

struct BrowserSyncLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser-sync-login",
        abstract: "Open the persistent Playwright browser profile so you can sign in to YouTube for browser-backed sync."
    )

    func run() async throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try await BrowserSyncService(repoRoot: repoRoot).openLoginSetup()
        print("Opened Playwright browser profile. Sign in to YouTube in that window, then stop the process when finished.")
    }
}

struct BrowserStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser-status",
        abstract: "Report browser executor readiness for browser-backed sync."
    )

    func run() async throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let status = try await BrowserSyncService(repoRoot: repoRoot).status()
        print("ready: \(status.ready ? "yes" : "no")")
        print("message: \(status.message)")
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

// MARK: - OAuth

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
            print("Granted scope: \(tokens.scope ?? "unknown")")
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
            if try store.channelById(channelId) == nil {
                try store.upsertChannel(ChannelRecord(
                    channelId: channelId,
                    name: item.channelTitle ?? channelId,
                    channelUrl: "https://www.youtube.com/channel/\(channelId)"
                ))
                channelStubs += 1
            }
            try store.setVideoChannelId(videoId: item.videoId, channelId: channelId)
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
                if try store.channelById(channelId) == nil {
                    try store.upsertChannel(ChannelRecord(
                        channelId: channelId,
                        name: item.channelTitle ?? channelId,
                        channelUrl: "https://www.youtube.com/channel/\(channelId)"
                    ))
                }
                try store.setVideoChannelId(videoId: item.videoId, channelId: channelId)
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
