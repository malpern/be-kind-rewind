import Foundation
import Testing
@testable import TaggingKit
@testable import VideoTagger

private actor MockYouTubeService: VideoTaggerYouTubeServing {
    var metadataByRequest: [[VideoMetadata]]
    var channelRecords: [ChannelRecord]
    var iconDataByURL: [String: Data]
    var iconFailures: Set<String>

    private(set) var requestedMetadataIDs: [[String]] = []
    private(set) var requestedChannelIDs: [[String]] = []
    private(set) var downloadedIconURLs: [String] = []

    init(
        metadataByRequest: [[VideoMetadata]] = [],
        channelRecords: [ChannelRecord] = [],
        iconDataByURL: [String: Data] = [:],
        iconFailures: Set<String> = []
    ) {
        self.metadataByRequest = metadataByRequest
        self.channelRecords = channelRecords
        self.iconDataByURL = iconDataByURL
        self.iconFailures = iconFailures
    }

    func fetchAllVideoMetadata(
        ids: [String],
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [VideoMetadata] {
        requestedMetadataIDs.append(ids)
        progress?(1, 1)
        if metadataByRequest.isEmpty {
            return []
        }
        return metadataByRequest.removeFirst()
    }

    func fetchChannelDetails(
        channelIds: [String],
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [ChannelRecord] {
        requestedChannelIDs.append(channelIds)
        progress?(1, 1)
        return channelRecords.filter { channelIds.contains($0.channelId) }
    }

    func downloadChannelIcon(url: URL) async throws -> Data {
        downloadedIconURLs.append(url.absoluteString)
        if iconFailures.contains(url.absoluteString) {
            throw YouTubeError.invalidResponse
        }
        return iconDataByURL[url.absoluteString] ?? Data()
    }
}

private final class StringLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

private func makeMetadata(
    videoId: String,
    viewCount: String = "1234",
    publishedAt: String = "2024-01-01T00:00:00Z",
    duration: String = "PT5M30S",
    channelId: String? = nil,
    channelTitle: String? = nil
) -> VideoMetadata {
    VideoMetadata(
        videoId: videoId,
        viewCount: viewCount,
        publishedAt: publishedAt,
        duration: duration,
        channelId: channelId,
        channelTitle: channelTitle
    )
}

private func makeChannelRecord(
    id: String,
    name: String,
    iconURL: String? = nil,
    fetchedAt: String? = nil
) -> ChannelRecord {
    ChannelRecord(
        channelId: id,
        name: name,
        handle: "@\(name.lowercased())",
        channelUrl: "https://www.youtube.com/channel/\(id)",
        iconUrl: iconURL,
        iconData: nil,
        subscriberCount: "1200",
        description: "\(name) channel",
        videoCountTotal: 42,
        fetchedAt: fetchedAt
    )
}

@Suite("VideoTagger YouTube Workflows")
struct VideoTaggerYouTubeWorkflowTests {
    @Test("backfillMetadata updates videos and creates channel stubs")
    func backfillMetadataUpdatesStore() async throws {
        let store = try TopicStore(inMemory: true)
        try store.importVideos([
            VideoItem(sourceIndex: 0, title: "First", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none"),
            VideoItem(sourceIndex: 1, title: "Second", videoUrl: nil, videoId: "vid-1", channelName: "Beta", metadataText: nil, unavailableKind: "none")
        ])
        let youtube = MockYouTubeService(metadataByRequest: [[
            makeMetadata(videoId: "vid-0", channelId: "chan-alpha", channelTitle: "Alpha"),
            makeMetadata(videoId: "vid-1", channelId: "chan-beta", channelTitle: "Beta")
        ]])
        let sink = StringLogSink()

        let summary = try await backfillMetadata(store: store, youtube: youtube, all: false) { sink.append($0) }

        let storedVideos = try store.unassignedVideos().sorted { $0.videoId < $1.videoId }
        let first = try #require(storedVideos.first)
        let second = try #require(storedVideos.dropFirst().first)
        #expect(summary.requestedVideoCount == 2)
        #expect(summary.updatedVideoCount == 2)
        #expect(summary.channelStubCount == 2)
        #expect(summary.missingVideoCount == 0)
        #expect(summary.quotaUnitsUsed == 1)
        #expect(first.viewCount == "1K views")
        #expect(first.duration == "5:30")
        #expect(first.channelId == "chan-alpha")
        #expect(second.channelId == "chan-beta")
        #expect(try store.channelById("chan-alpha")?.name == "Alpha")
        #expect(try store.channelById("chan-beta")?.name == "Beta")
        #expect(await youtube.requestedMetadataIDs == [["vid-0", "vid-1"]])
        let logs = sink.snapshot().joined(separator: "\n")
        #expect(logs.contains("Fetching metadata for 2 videos missing metadata"))
        #expect(logs.contains("Created 2 channel stubs"))
    }

    @Test("backfillMetadata returns early when nothing is missing")
    func backfillMetadataSkipsWhenComplete() async throws {
        let store = try TopicStore(inMemory: true)
        try store.importVideos([
            VideoItem(sourceIndex: 0, title: "First", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none")
        ])
        try store.updateVideoMetadata(videoId: "vid-0", viewCount: "1K views", publishedAt: "today", duration: "5:30")
        let youtube = MockYouTubeService()
        let sink = StringLogSink()

        let summary = try await backfillMetadata(store: store, youtube: youtube, all: false) { sink.append($0) }

        #expect(summary.requestedVideoCount == 0)
        #expect(summary.updatedVideoCount == 0)
        #expect(await youtube.requestedMetadataIDs.isEmpty)
        #expect(sink.snapshot() == ["All videos already have metadata."])
    }

    @Test("backfillMetadata with all=true refetches already populated videos")
    func backfillMetadataAllRefetchesEverything() async throws {
        let store = try TopicStore(inMemory: true)
        try store.importVideos([
            VideoItem(sourceIndex: 0, title: "First", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none")
        ])
        try store.updateVideoMetadata(videoId: "vid-0", viewCount: "old", publishedAt: "old", duration: "old")
        let youtube = MockYouTubeService(metadataByRequest: [[
            makeMetadata(videoId: "vid-0", viewCount: "999", duration: "PT1M5S", channelId: "chan-alpha", channelTitle: "Alpha")
        ]])
        let sink = StringLogSink()

        let summary = try await backfillMetadata(store: store, youtube: youtube, all: true) { sink.append($0) }

        let stored = try #require(try store.unassignedVideos().first)
        #expect(summary.requestedVideoCount == 1)
        #expect(summary.updatedVideoCount == 1)
        #expect(stored.viewCount == "999 views")
        #expect(stored.duration == "1:05")
        #expect(await youtube.requestedMetadataIDs == [["vid-0"]])
        #expect(sink.snapshot().joined(separator: "\n").contains("Fetching metadata for all 1 videos"))
    }

    @Test("enrichChannels backfills ids, refreshes records, and caches icons")
    func enrichChannelsPerformsAllSteps() async throws {
        let store = try TopicStore(inMemory: true)
        try store.importVideos([
            VideoItem(sourceIndex: 0, title: "First", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none"),
            VideoItem(sourceIndex: 1, title: "Second", videoUrl: nil, videoId: "vid-1", channelName: "Beta", metadataText: nil, unavailableKind: "none")
        ])
        try store.upsertChannel(makeChannelRecord(
            id: "chan-beta",
            name: "Beta",
            iconURL: "https://example.com/beta.png",
            fetchedAt: "2000-01-01T00:00:00Z"
        ))
        try store.setVideoChannelId(videoId: "vid-1", channelId: "chan-beta")

        let youtube = MockYouTubeService(
            metadataByRequest: [[
                makeMetadata(videoId: "vid-0", channelId: "chan-alpha", channelTitle: "Alpha")
            ]],
            channelRecords: [
                makeChannelRecord(id: "chan-alpha", name: "Alpha", iconURL: "https://example.com/alpha.png", fetchedAt: "2026-04-03T12:00:00Z"),
                makeChannelRecord(id: "chan-beta", name: "Beta Updated", iconURL: "https://example.com/beta.png", fetchedAt: "2026-04-03T12:00:00Z")
            ],
            iconDataByURL: [
                "https://example.com/alpha.png": Data([1, 2, 3]),
                "https://example.com/beta.png": Data([4, 5, 6])
            ]
        )
        let sink = StringLogSink()

        let summary = try await enrichChannels(
            store: store,
            youtube: youtube,
            force: false,
            maxAgeDays: 90
        ) { sink.append($0) }

        let alpha = try #require(try store.channelById("chan-alpha"))
        let beta = try #require(try store.channelById("chan-beta"))
        #expect(summary.backfilledVideoCount == 1)
        #expect(summary.updatedChannelCount == 2)
        #expect(summary.cachedIconCount == 2)
        #expect(summary.quotaUnitsUsed == 2)
        #expect(alpha.iconData == Data([1, 2, 3]))
        #expect(beta.name == "Beta Updated")
        #expect(beta.iconData == Data([4, 5, 6]))
        #expect(await youtube.requestedMetadataIDs == [["vid-0"]])
        #expect(await youtube.requestedChannelIDs == [["chan-alpha", "chan-beta"]])
        #expect(Set(await youtube.downloadedIconURLs) == Set(["https://example.com/alpha.png", "https://example.com/beta.png"]))
        let logs = sink.snapshot().joined(separator: "\n")
        #expect(logs.contains("Step 1: Backfilling channel_id for 1 videos"))
        #expect(logs.contains("Step 2: Enriching 2 of 2 channels"))
        #expect(logs.contains("Cached 2 icons locally"))
    }

    @Test("enrichChannels skips channel refresh when data is current")
    func enrichChannelsSkipsFreshChannels() async throws {
        let store = try TopicStore(inMemory: true)
        try store.importVideos([
            VideoItem(sourceIndex: 0, title: "Only", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none")
        ])
        try store.upsertChannel(makeChannelRecord(
            id: "chan-alpha",
            name: "Alpha",
            fetchedAt: "2026-04-03T00:00:00Z"
        ))
        try store.setVideoChannelId(videoId: "vid-0", channelId: "chan-alpha")
        let youtube = MockYouTubeService()
        let sink = StringLogSink()

        let summary = try await enrichChannels(
            store: store,
            youtube: youtube,
            force: false,
            maxAgeDays: 3650
        ) { sink.append($0) }

        #expect(summary.backfilledVideoCount == 0)
        #expect(summary.updatedChannelCount == 0)
        #expect(summary.cachedIconCount == 0)
        #expect(summary.quotaUnitsUsed == 0)
        #expect(await youtube.requestedMetadataIDs.isEmpty)
        #expect(await youtube.requestedChannelIDs.isEmpty)
        let logs = sink.snapshot().joined(separator: "\n")
        #expect(logs.contains("Step 1: All videos already have channel_id. Skipping. (0 quota units)"))
        #expect(logs.contains("Step 2: All 1 channels up to date. (0 quota units)"))
        #expect(logs.contains("Step 3: All channel icons already cached. (0 quota units)"))
    }

    @Test("enrichChannels force refreshes channels even when fetched recently")
    func enrichChannelsForceRefreshesCurrentChannels() async throws {
        let store = try TopicStore(inMemory: true)
        try store.importVideos([
            VideoItem(sourceIndex: 0, title: "Only", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none")
        ])
        try store.upsertChannel(makeChannelRecord(
            id: "chan-alpha",
            name: "Alpha",
            iconURL: "https://example.com/alpha.png",
            fetchedAt: "2026-04-03T00:00:00Z"
        ))
        try store.setVideoChannelId(videoId: "vid-0", channelId: "chan-alpha")
        let youtube = MockYouTubeService(
            channelRecords: [
                makeChannelRecord(
                    id: "chan-alpha",
                    name: "Alpha Refreshed",
                    iconURL: "https://example.com/alpha.png",
                    fetchedAt: "2026-04-03T12:00:00Z"
                )
            ],
            iconDataByURL: ["https://example.com/alpha.png": Data([7, 8, 9])]
        )
        let sink = StringLogSink()

        let summary = try await enrichChannels(
            store: store,
            youtube: youtube,
            force: true,
            maxAgeDays: 3650
        ) { sink.append($0) }

        let channel = try #require(try store.channelById("chan-alpha"))
        #expect(summary.updatedChannelCount == 1)
        #expect(summary.cachedIconCount == 1)
        #expect(await youtube.requestedChannelIDs == [["chan-alpha"]])
        #expect(channel.name == "Alpha Refreshed")
        #expect(channel.iconData == Data([7, 8, 9]))
        #expect(sink.snapshot().joined(separator: "\n").contains("Step 2: Enriching 1 of 1 channels"))
    }

    @Test("verifyPlaylistMemberships stores only videos already known to the DB")
    func verifyPlaylistMembershipsFiltersUnknownVideos() async throws {
        let store = try TopicStore(inMemory: true)
        try store.importVideos([
            VideoItem(sourceIndex: 0, title: "First", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none"),
            VideoItem(sourceIndex: 1, title: "Second", videoUrl: nil, videoId: "vid-1", channelName: "Beta", metadataText: nil, unavailableKind: "none")
        ])

        let count = try await verifyPlaylistMemberships(
            store: store,
            playlistId: "PL123",
            title: "Useful Playlist",
            verifiedAt: "2026-04-03T12:00:00Z"
        ) { _ in
            [
                PlaylistVideoItem(videoId: "vid-0", title: "First", channelId: "chan-alpha", channelTitle: "Alpha", position: 0),
                PlaylistVideoItem(videoId: "external-vid", title: "Outside", channelId: "chan-ext", channelTitle: "Ext", position: 1)
            ]
        }

        let includedPlaylists = try store.playlistsForVideo(videoId: "vid-0")
        let excludedPlaylists = try store.playlistsForVideo(videoId: "vid-1")
        #expect(count == 1)
        #expect(includedPlaylists.map(\.playlistId) == ["PL123"])
        #expect(includedPlaylists.first?.title == "Useful Playlist")
        #expect(excludedPlaylists.isEmpty)
        #expect(try store.knownPlaylists().map(\.playlistId) == ["PL123"])
    }

    @Test("verifyPlaylistMemberships replaces prior memberships for the playlist")
    func verifyPlaylistMembershipsReplacesExistingMemberships() async throws {
        let store = try TopicStore(inMemory: true)
        try store.importVideos([
            VideoItem(sourceIndex: 0, title: "First", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none"),
            VideoItem(sourceIndex: 1, title: "Second", videoUrl: nil, videoId: "vid-1", channelName: "Beta", metadataText: nil, unavailableKind: "none")
        ])

        _ = try await verifyPlaylistMemberships(
            store: store,
            playlistId: "PL123",
            title: "Useful Playlist",
            verifiedAt: "2026-04-03T12:00:00Z"
        ) { _ in
            [PlaylistVideoItem(videoId: "vid-0", title: "First", channelId: nil, channelTitle: nil, position: 0)]
        }

        _ = try await verifyPlaylistMemberships(
            store: store,
            playlistId: "PL123",
            title: "Useful Playlist",
            verifiedAt: "2026-04-03T12:05:00Z"
        ) { _ in
            [PlaylistVideoItem(videoId: "vid-1", title: "Second", channelId: nil, channelTitle: nil, position: 3)]
        }

        #expect(try store.playlistsForVideo(videoId: "vid-0").isEmpty)
        #expect(try store.playlistsForVideo(videoId: "vid-1").map(\.playlistId) == ["PL123"])
    }
}
