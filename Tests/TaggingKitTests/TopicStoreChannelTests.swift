import Foundation
import Testing
@testable import TaggingKit

private func makeChannel(
    id: String,
    name: String,
    iconData: Data? = nil,
    fetchedAt: String? = "2026-04-03T00:00:00Z"
) -> ChannelRecord {
    ChannelRecord(
        channelId: id,
        name: name,
        handle: "@\(name.lowercased().replacing(" ", with: ""))",
        channelUrl: "https://www.youtube.com/channel/\(id)",
        iconUrl: "https://example.com/\(id).png",
        iconData: iconData,
        subscriberCount: "12345",
        description: "\(name) description",
        videoCountTotal: 42,
        fetchedAt: fetchedAt
    )
}

private func makeStoreWithAssignedVideos() throws -> (TopicStore, Int64, Int64) {
    let store = try TopicStore(inMemory: true)
    let items = [
        VideoItem(sourceIndex: 0, title: "Main 0", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none"),
        VideoItem(sourceIndex: 1, title: "Main 1", videoUrl: nil, videoId: "vid-1", channelName: "Alpha", metadataText: nil, unavailableKind: "none"),
        VideoItem(sourceIndex: 2, title: "Sub 2", videoUrl: nil, videoId: "vid-2", channelName: "Beta", metadataText: nil, unavailableKind: "none"),
        VideoItem(sourceIndex: 3, title: "Other 3", videoUrl: nil, videoId: "vid-3", channelName: "Gamma", metadataText: nil, unavailableKind: "none")
    ]
    try store.importVideos(items)

    let mainTopic = try store.createTopic(name: "Main")
    let subtopic = try store.createSubtopic(name: "Sub", parentId: mainTopic)
    let otherTopic = try store.createTopic(name: "Other")

    try store.assignVideos(indices: [0, 1], toTopic: mainTopic)
    try store.assignVideos(indices: [2], toTopic: subtopic)
    try store.assignVideos(indices: [3], toTopic: otherTopic)

    try store.upsertChannel(makeChannel(id: "chan-alpha", name: "Alpha", iconData: Data([1, 2, 3])))
    try store.upsertChannel(makeChannel(id: "chan-beta", name: "Beta"))
    try store.upsertChannel(makeChannel(id: "chan-gamma", name: "Gamma"))

    try store.setVideoChannelId(videoId: "vid-0", channelId: "chan-alpha")
    try store.setVideoChannelId(videoId: "vid-1", channelId: "chan-alpha")
    try store.setVideoChannelId(videoId: "vid-2", channelId: "chan-beta")
    try store.setVideoChannelId(videoId: "vid-3", channelId: "chan-gamma")

    return (store, mainTopic, subtopic)
}

@Suite("TopicStore — Channels")
struct TopicStoreChannelTests {
    @Test("upserts and reloads a channel record")
    func upsertAndLookupChannel() throws {
        let store = try TopicStore(inMemory: true)
        try store.upsertChannel(makeChannel(id: "chan-1", name: "Alpha", iconData: Data([9, 8, 7])))

        let loadedChannel = try store.channelById("chan-1")
        let channel = try #require(loadedChannel)
        #expect(channel.id == "chan-1")
        #expect(channel.name == "Alpha")
        #expect(channel.handle == "@alpha")
        #expect(channel.videoCountTotal == 42)
        #expect(channel.iconData == Data([9, 8, 7]))
    }

    @Test("reports missing channel IDs until videos are linked")
    func missingChannelIdsReflectLinkedVideos() throws {
        let store = try TopicStore(inMemory: true)
        try store.importVideos([
            VideoItem(sourceIndex: 0, title: "One", videoUrl: nil, videoId: "vid-0", channelName: "Alpha", metadataText: nil, unavailableKind: "none"),
            VideoItem(sourceIndex: 1, title: "Two", videoUrl: nil, videoId: "vid-1", channelName: "Beta", metadataText: nil, unavailableKind: "none")
        ])

        #expect(try store.videoIdsMissingChannelId() == ["vid-0", "vid-1"])

        try store.upsertChannel(makeChannel(id: "chan-alpha", name: "Alpha"))
        try store.setVideoChannelId(videoId: "vid-0", channelId: "chan-alpha")

        #expect(try store.videoIdsMissingChannelId() == ["vid-1"])
        #expect(try store.allChannelIds() == ["chan-alpha"])
    }

    @Test("channelsForTopicIncludingSubtopics aggregates and sorts by count")
    func channelsIncludingSubtopicsAggregateCounts() throws {
        let (store, mainTopic, _) = try makeStoreWithAssignedVideos()

        let directChannels = try store.channelsForTopic(id: mainTopic)
        #expect(directChannels.map(\.channelId) == ["chan-alpha"])

        let aggregatedChannels = try store.channelsForTopicIncludingSubtopics(id: mainTopic)
        #expect(aggregatedChannels.map(\.channelId) == ["chan-alpha", "chan-beta"])
        #expect(try store.videoCountForChannel(channelId: "chan-alpha", inTopic: mainTopic) == 2)
        #expect(try store.videoCountForChannel(channelId: "chan-beta", inTopic: mainTopic) == 1)
    }

    @Test("videosForTopicByChannel includes subtopic videos and preserves source order")
    func videosForTopicByChannelIncludesSubtopics() throws {
        let (store, mainTopic, _) = try makeStoreWithAssignedVideos()

        let alphaVideos = try store.videosForTopicByChannel(topicId: mainTopic, channelId: "chan-alpha")
        #expect(alphaVideos.map(\.videoId) == ["vid-0", "vid-1"])

        let betaVideos = try store.videosForTopicByChannel(topicId: mainTopic, channelId: "chan-beta")
        #expect(betaVideos.map(\.videoId) == ["vid-2"])
        let beta = try #require(betaVideos.first)
        #expect(beta.topicId != mainTopic)
        #expect(beta.channelId == "chan-beta")
    }

    @Test("updateChannelIcon replaces icon bytes and stamps fetched time")
    func updateChannelIconPersistsBytes() throws {
        let store = try TopicStore(inMemory: true)
        try store.upsertChannel(makeChannel(id: "chan-1", name: "Alpha", iconData: Data([1])))

        try store.updateChannelIcon(channelId: "chan-1", iconData: Data([4, 5, 6]))

        let loadedChannel = try store.channelById("chan-1")
        let channel = try #require(loadedChannel)
        #expect(channel.iconData == Data([4, 5, 6]))
        #expect(channel.iconFetchedAt != nil)
    }
}
