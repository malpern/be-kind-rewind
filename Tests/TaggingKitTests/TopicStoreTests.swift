import Foundation
import Testing
@testable import TaggingKit

// MARK: - Test Helpers

private func makeStore(videoCount: Int = 10) throws -> (TopicStore, [VideoItem]) {
    let store = try TopicStore(inMemory: true)
    let items = (0..<videoCount).map { i in
        VideoItem(sourceIndex: i, title: "Video \(i)", videoUrl: "https://youtube.com/watch?v=vid\(i)",
                  videoId: "vid-\(i)", channelName: "Channel \(i % 3)", metadataText: nil, unavailableKind: "none")
    }
    try store.importVideos(items)
    return (store, items)
}

// MARK: - Import Tests

@Suite("TopicStore — Import")
struct TopicStoreImportTests {
    @Test("imports videos and counts them")
    func importVideos() throws {
        let (store, _) = try makeStore(videoCount: 20)
        #expect(try store.totalVideoCount() == 20)
        #expect(try store.unassignedCount() == 20)
    }

    @Test("import replaces existing videos with same ID")
    func importReplace() throws {
        let store = try TopicStore(inMemory: true)
        let v1 = [VideoItem(sourceIndex: 0, title: "Original", videoUrl: nil,
                             videoId: "v1", channelName: nil, metadataText: nil, unavailableKind: "none")]
        try store.importVideos(v1)
        #expect(try store.totalVideoCount() == 1)

        let v2 = [VideoItem(sourceIndex: 0, title: "Updated", videoUrl: nil,
                             videoId: "v1", channelName: nil, metadataText: nil, unavailableKind: "none")]
        try store.importVideos(v2)
        #expect(try store.totalVideoCount() == 1) // Still 1, not 2
    }

    @Test("skips videos without videoId")
    func skipNoId() throws {
        let store = try TopicStore(inMemory: true)
        let items = [VideoItem(sourceIndex: 0, title: "No ID", videoUrl: nil,
                               videoId: nil, channelName: nil, metadataText: nil, unavailableKind: "none")]
        try store.importVideos(items)
        #expect(try store.totalVideoCount() == 0)
    }
}

// MARK: - Topic CRUD Tests

@Suite("TopicStore — Topics")
struct TopicStoreCRUDTests {
    @Test("creates topics and lists them sorted by count")
    func createAndList() throws {
        let (store, _) = try makeStore()

        let t1 = try store.createTopic(name: "Small")
        let t2 = try store.createTopic(name: "Big")
        try store.assignVideos(indices: [0, 1], toTopic: t1)
        try store.assignVideos(indices: [2, 3, 4, 5, 6], toTopic: t2)

        let topics = try store.listTopics()
        #expect(topics.count == 2)
        #expect(topics[0].name == "Big") // Sorted by count desc
        #expect(topics[0].videoCount == 5)
        #expect(topics[1].name == "Small")
        #expect(topics[1].videoCount == 2)
    }

    @Test("renames a topic")
    func rename() throws {
        let (store, _) = try makeStore()
        let topicId = try store.createTopic(name: "Old Name")
        try store.renameTopic(id: topicId, to: "New Name")

        let topics = try store.listTopics()
        #expect(topics[0].name == "New Name")
    }

    @Test("deletes a topic and unassigns its videos")
    func deleteUnassigns() throws {
        let (store, _) = try makeStore(videoCount: 5)
        let topicId = try store.createTopic(name: "Doomed")
        try store.assignVideos(indices: [0, 1, 2], toTopic: topicId)
        #expect(try store.unassignedCount() == 2)

        try store.deleteTopic(id: topicId)
        #expect(try store.listTopics().count == 0)
        #expect(try store.unassignedCount() == 5) // All back to unassigned
    }

    @Test("merges source topic into target")
    func merge() throws {
        let (store, _) = try makeStore(videoCount: 6)
        let t1 = try store.createTopic(name: "Keep")
        let t2 = try store.createTopic(name: "Merge Away")
        try store.assignVideos(indices: [0, 1, 2], toTopic: t1)
        try store.assignVideos(indices: [3, 4, 5], toTopic: t2)

        try store.mergeTopic(sourceId: t2, intoId: t1)

        let topics = try store.listTopics()
        #expect(topics.count == 1)
        #expect(topics[0].name == "Keep")
        #expect(topics[0].videoCount == 6)
    }

    @Test("topicIdByName finds existing topic")
    func findByName() throws {
        let (store, _) = try makeStore()
        let topicId = try store.createTopic(name: "Find Me")
        let found = try store.topicIdByName("Find Me")
        #expect(found == topicId)
    }

    @Test("topicIdByName returns nil for missing topic")
    func findMissing() throws {
        let (store, _) = try makeStore()
        let found = try store.topicIdByName("Nonexistent")
        #expect(found == nil)
    }
}

// MARK: - Assignment Tests

@Suite("TopicStore — Assignments")
struct TopicStoreAssignmentTests {
    @Test("assigns individual video by videoId")
    func assignById() throws {
        let (store, _) = try makeStore(videoCount: 3)
        let topicId = try store.createTopic(name: "Target")
        try store.assignVideo(videoId: "vid-1", toTopic: topicId)

        let videos = try store.videosForTopic(id: topicId)
        #expect(videos.count == 1)
        #expect(videos[0].videoId == "vid-1")
    }

    @Test("assigns multiple videos by source index")
    func assignByIndex() throws {
        let (store, _) = try makeStore(videoCount: 5)
        let topicId = try store.createTopic(name: "Batch")
        try store.assignVideos(indices: [0, 2, 4], toTopic: topicId)

        let videos = try store.videosForTopic(id: topicId)
        #expect(videos.count == 3)
        #expect(try store.unassignedCount() == 2)
    }

    @Test("reassigning a video moves it between topics")
    func reassign() throws {
        let (store, _) = try makeStore(videoCount: 3)
        let t1 = try store.createTopic(name: "First")
        let t2 = try store.createTopic(name: "Second")
        try store.assignVideo(videoId: "vid-0", toTopic: t1)
        #expect(try store.videosForTopic(id: t1).count == 1)

        try store.assignVideo(videoId: "vid-0", toTopic: t2)
        #expect(try store.videosForTopic(id: t1).count == 0)
        #expect(try store.videosForTopic(id: t2).count == 1)
    }

    @Test("videosForTopic respects limit")
    func limitedQuery() throws {
        let (store, _) = try makeStore(videoCount: 20)
        let topicId = try store.createTopic(name: "Big")
        try store.assignVideos(indices: Array(0..<20), toTopic: topicId)

        let limited = try store.videosForTopic(id: topicId, limit: 5)
        #expect(limited.count == 5)

        let unlimited = try store.videosForTopic(id: topicId)
        #expect(unlimited.count == 20)
    }

    @Test("unassignedVideoItems returns correct VideoItem objects")
    func unassignedItems() throws {
        let (store, _) = try makeStore(videoCount: 5)
        let topicId = try store.createTopic(name: "Partial")
        try store.assignVideos(indices: [0, 1], toTopic: topicId)

        let unassigned = try store.unassignedVideoItems()
        #expect(unassigned.count == 3)
        #expect(unassigned.allSatisfy { $0.videoId != nil })
    }

    @Test("unassignedVideos returns StoredVideo objects")
    func unassignedStored() throws {
        let (store, _) = try makeStore(videoCount: 4)
        let topicId = try store.createTopic(name: "Some")
        try store.assignVideos(indices: [0], toTopic: topicId)

        let unassigned = try store.unassignedVideos()
        #expect(unassigned.count == 3)
    }
}

// MARK: - Commit Table Tests

@Suite("TopicStore — Commit Table")
struct TopicStoreCommitTests {
    @Test("queues and retrieves sync actions")
    func basicQueue() throws {
        let store = try TopicStore(inMemory: true)
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "Old Watch")

        let plan = try store.pendingSyncPlan()
        #expect(plan.count == 1)
        #expect(plan[0].videoId == "v1")
        #expect(plan[0].playlist == "Old Watch")
    }

    @Test("collapses redundant moves to net effect")
    func collapseNetEffect() throws {
        let store = try TopicStore(inMemory: true)
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "A")
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "B")
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "C")

        let plan = try store.pendingSyncPlan()
        #expect(plan.count == 1)
        #expect(plan[0].playlist == "C")
    }

    @Test("handles multiple videos independently")
    func multipleVideos() throws {
        let store = try TopicStore(inMemory: true)
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "A")
        try store.queueCommit(action: "add_to_playlist", videoId: "v2", playlist: "B")
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "C")

        let plan = try store.pendingSyncPlan()
        #expect(plan.count == 2)
        let v1Action = plan.first { $0.videoId == "v1" }
        let v2Action = plan.first { $0.videoId == "v2" }
        #expect(v1Action?.playlist == "C")
        #expect(v2Action?.playlist == "B")
    }

    @Test("markSynced clears pending actions")
    func markSynced() throws {
        let store = try TopicStore(inMemory: true)
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "A")
        #expect(try store.pendingSyncPlan().count == 1)

        try store.markSynced()
        #expect(try store.pendingSyncPlan().count == 0)
    }

    @Test("new commits after markSynced are pending")
    func newAfterSync() throws {
        let store = try TopicStore(inMemory: true)
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "A")
        try store.markSynced()

        try store.queueCommit(action: "add_to_playlist", videoId: "v2", playlist: "B")
        let plan = try store.pendingSyncPlan()
        #expect(plan.count == 1)
        #expect(plan[0].videoId == "v2")
    }
}

// MARK: - VideoItem Tests

@Suite("VideoItem")
struct VideoItemTests {
    @Test("embeddingText combines title and channel")
    func embeddingText() {
        let item = VideoItem(sourceIndex: 0, title: "Cool Video", videoUrl: nil,
                             videoId: "v1", channelName: "Tech Channel", metadataText: nil, unavailableKind: "none")
        #expect(item.embeddingText == "Cool Video — Tech Channel")
    }

    @Test("embeddingText uses title only when no channel")
    func embeddingTextNoChannel() {
        let item = VideoItem(sourceIndex: 0, title: "Solo", videoUrl: nil,
                             videoId: "v1", channelName: nil, metadataText: nil, unavailableKind: "none")
        #expect(item.embeddingText == "Solo")
    }

    @Test("embeddingText returns nil for missing title")
    func embeddingTextNoTitle() {
        let item = VideoItem(sourceIndex: 0, title: nil, videoUrl: nil,
                             videoId: "v1", channelName: "Ch", metadataText: nil, unavailableKind: "none")
        #expect(item.embeddingText == nil)
    }

    @Test("id uses videoId when available")
    func idFromVideoId() {
        let item = VideoItem(sourceIndex: 5, title: "T", videoUrl: nil,
                             videoId: "abc123", channelName: nil, metadataText: nil, unavailableKind: "none")
        #expect(item.id == "abc123")
    }

    @Test("id falls back to sourceIndex")
    func idFallback() {
        let item = VideoItem(sourceIndex: 42, title: "T", videoUrl: nil,
                             videoId: nil, channelName: nil, metadataText: nil, unavailableKind: "none")
        #expect(item.id == "index-42")
    }
}

// MARK: - InventoryLoader Tests

@Suite("InventoryLoader")
struct InventoryLoaderTests {
    @Test("loads valid inventory JSON")
    func loadValid() throws {
        let json = """
        {
            "total": 2,
            "capturedAt": "2026-04-01T00:00:00Z",
            "items": [
                {"sourceIndex": 1, "title": "Video 1", "videoId": "v1", "videoUrl": null, "channelName": "Ch", "metadataText": null, "unavailableKind": "none"},
                {"sourceIndex": 2, "title": "Video 2", "videoId": "v2", "videoUrl": null, "channelName": null, "metadataText": null, "unavailableKind": "deleted"}
            ]
        }
        """
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("test-inventory.json")
        try json.write(to: tempUrl, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempUrl) }

        let snapshot = try InventoryLoader.load(from: tempUrl)
        #expect(snapshot.total == 2)
        #expect(snapshot.items.count == 2)
        #expect(snapshot.items[0].title == "Video 1")
        #expect(snapshot.items[1].unavailableKind == "deleted")
    }
}
