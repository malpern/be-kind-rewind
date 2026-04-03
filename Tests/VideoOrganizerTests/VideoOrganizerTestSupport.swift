import Foundation
@testable import TaggingKit

func withTemporaryDirectory<Result>(
    _ body: (URL) throws -> Result
) throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

func withTemporaryDirectory<Result>(
    _ body: (URL) async throws -> Result
) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

func makeOrganizerStoreFixture(at dbPath: String) throws {
    let store = try TopicStore(path: dbPath)
    try store.importVideos([
        VideoItem(sourceIndex: 0, title: "Alpha SwiftUI Basics", videoUrl: "https://youtube.com/watch?v=vid-0", videoId: "vid-0", channelName: "Alpha Channel", metadataText: nil, unavailableKind: "none"),
        VideoItem(sourceIndex: 1, title: "Alpha Advanced Layout", videoUrl: "https://youtube.com/watch?v=vid-1", videoId: "vid-1", channelName: "Alpha Channel", metadataText: nil, unavailableKind: "none"),
        VideoItem(sourceIndex: 2, title: "Beta Animations", videoUrl: "https://youtube.com/watch?v=vid-2", videoId: "vid-2", channelName: "Beta Channel", metadataText: nil, unavailableKind: "none"),
        VideoItem(sourceIndex: 3, title: "Gamma Debugging", videoUrl: "https://youtube.com/watch?v=vid-3", videoId: "vid-3", channelName: "Gamma Channel", metadataText: nil, unavailableKind: "none")
    ])

    let alphaTopic = try store.createTopic(name: "Alpha Topic")
    let betaTopic = try store.createTopic(name: "Beta Topic")
    let alphaSubtopic = try store.createSubtopic(name: "Alpha Subtopic", parentId: alphaTopic)

    try store.assignVideos(indices: [0], toTopic: alphaTopic)
    try store.assignVideos(indices: [1], toTopic: alphaSubtopic)
    try store.assignVideos(indices: [2], toTopic: betaTopic)

    try store.updateVideoMetadata(videoId: "vid-0", viewCount: "1.2M views", publishedAt: "10 days ago", duration: "12:34")
    try store.updateVideoMetadata(videoId: "vid-1", viewCount: "340K views", publishedAt: "today", duration: "8:00")
    try store.updateVideoMetadata(videoId: "vid-2", viewCount: "800 views", publishedAt: "2 months ago", duration: "5:00")

    try store.upsertChannel(ChannelRecord(
        channelId: "chan-alpha",
        name: "Alpha Channel",
        handle: "@alpha",
        channelUrl: "https://www.youtube.com/channel/chan-alpha",
        iconUrl: "https://example.com/alpha.png",
        iconData: Data([1, 2, 3]),
        subscriberCount: "150000",
        description: "Alpha videos",
        videoCountTotal: 10,
        fetchedAt: "2026-04-03T00:00:00Z"
    ))
    try store.upsertChannel(ChannelRecord(
        channelId: "chan-beta",
        name: "Beta Channel",
        handle: "@beta",
        channelUrl: "https://www.youtube.com/channel/chan-beta",
        iconUrl: "https://example.com/beta.png",
        iconData: nil,
        subscriberCount: "9000",
        description: "Beta videos",
        videoCountTotal: 25,
        fetchedAt: "2026-04-03T00:00:00Z"
    ))

    try store.setVideoChannelId(videoId: "vid-0", channelId: "chan-alpha")
    try store.setVideoChannelId(videoId: "vid-1", channelId: "chan-alpha")
    try store.setVideoChannelId(videoId: "vid-2", channelId: "chan-beta")

    try store.upsertPlaylist(PlaylistRecord(
        playlistId: "PL-ALPHA",
        title: "Alpha Favorites",
        visibility: "public",
        videoCount: 2,
        source: "test",
        fetchedAt: "2026-04-03T00:00:00Z"
    ))
    try store.replacePlaylistMemberships(playlistId: "PL-ALPHA", memberships: [
        PlaylistMembershipRecord(playlistId: "PL-ALPHA", videoId: "vid-0", position: 0, verifiedAt: "2026-04-03T00:00:00Z"),
        PlaylistMembershipRecord(playlistId: "PL-ALPHA", videoId: "vid-1", position: 1, verifiedAt: "2026-04-03T00:00:00Z")
    ])
}
