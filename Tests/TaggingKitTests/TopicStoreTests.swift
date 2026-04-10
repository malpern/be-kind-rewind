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
        let stored = try #require(store.unassignedVideos().first)
        #expect(stored.videoId == "v1")
        #expect(stored.title == "Updated")
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
        #expect(plan.count == 3)
        #expect(Set(plan.map(\.playlist)) == Set(["A", "B", "C"]))
    }

    @Test("handles multiple videos independently")
    func multipleVideos() throws {
        let store = try TopicStore(inMemory: true)
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "A")
        try store.queueCommit(action: "add_to_playlist", videoId: "v2", playlist: "B")
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "C")

        let plan = try store.pendingSyncPlan()
        #expect(plan.count == 3)
        let v1Actions = plan.filter { $0.videoId == "v1" }
        let v2Action = plan.first { $0.videoId == "v2" }
        #expect(Set(v1Actions.map(\.playlist)) == Set(["A", "C"]))
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

    @Test("routes Watch Later and Not Interested to the browser executor")
    func executorRouting() throws {
        let store = try TopicStore(inMemory: true)
        try store.queueCommit(action: "add_to_playlist", videoId: "v1", playlist: "WL")
        try store.queueCommit(action: "not_interested", videoId: "v2", playlist: "__youtube__")
        try store.queueCommit(action: "add_to_playlist", videoId: "v3", playlist: "PL123")

        let browserPlan = try store.pendingSyncPlan(executor: .browser)
        let apiPlan = try store.pendingSyncPlan(executor: .api)

        #expect(Set(browserPlan.map(\.videoId)) == Set(["v1", "v2"]))
        #expect(browserPlan.allSatisfy { $0.executor == .browser })
        #expect(apiPlan.map(\.videoId) == ["v3"])
        #expect(apiPlan.allSatisfy { $0.executor == .api })
    }
}

@Suite("TopicStore — Candidates")
struct TopicStoreCandidateTests {
    @Test("saved candidates stay visible while dismissed and watched are excluded")
    func candidateStateFiltering() throws {
        let store = try TopicStore(inMemory: true)
        let topicId = try store.createTopic(name: "Candidates")
        try store.replaceCandidates(
            forTopic: topicId,
            candidates: [
                TopicCandidate(topicId: topicId, videoId: "keep", title: "Keep", channelId: "c1", channelName: "Alpha", videoUrl: nil, viewCount: nil, publishedAt: nil, duration: nil, channelIconUrl: nil, score: 5, reason: "keep", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                TopicCandidate(topicId: topicId, videoId: "saved", title: "Saved", channelId: "c1", channelName: "Alpha", videoUrl: nil, viewCount: nil, publishedAt: nil, duration: nil, channelIconUrl: nil, score: 4, reason: "saved", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                TopicCandidate(topicId: topicId, videoId: "dismissed", title: "Dismissed", channelId: "c1", channelName: "Alpha", videoUrl: nil, viewCount: nil, publishedAt: nil, duration: nil, channelIconUrl: nil, score: 3, reason: "dismissed", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                TopicCandidate(topicId: topicId, videoId: "watched", title: "Watched", channelId: "c1", channelName: "Alpha", videoUrl: nil, viewCount: nil, publishedAt: nil, duration: nil, channelIconUrl: nil, score: 2, reason: "watched", state: CandidateState.candidate.rawValue, discoveredAt: nil)
            ],
            sources: []
        )

        try store.setCandidateState(topicId: topicId, videoId: "saved", state: .saved)
        try store.setCandidateState(topicId: topicId, videoId: "dismissed", state: .dismissed)
        try store.setCandidateState(topicId: topicId, videoId: "watched", state: .watched)

        let visible = try store.candidatesForTopic(id: topicId)
        #expect(Set(visible.map(\.videoId)) == Set(["keep", "saved"]))
    }

    @Test("app seen events soft-derank but do not hide candidates")
    func appSeenEventsRemainVisible() throws {
        let store = try TopicStore(inMemory: true)
        let topicId = try store.createTopic(name: "Candidates")
        try store.replaceCandidates(
            forTopic: topicId,
            candidates: [
                TopicCandidate(topicId: topicId, videoId: "keep", title: "Keep", channelId: "c1", channelName: "Alpha", videoUrl: nil, viewCount: nil, publishedAt: nil, duration: nil, channelIconUrl: nil, score: 5, reason: "keep", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                TopicCandidate(topicId: topicId, videoId: "opened", title: "Opened", channelId: "c2", channelName: "Beta", videoUrl: nil, viewCount: nil, publishedAt: nil, duration: nil, channelIconUrl: nil, score: 4, reason: "opened", state: CandidateState.candidate.rawValue, discoveredAt: nil)
            ],
            sources: []
        )

        _ = try store.recordSeenVideo(
            videoId: "opened",
            title: "Opened",
            channelName: "Beta",
            rawURL: "https://youtube.com/watch?v=opened",
            source: .app,
            confidence: .probable
        )

        let visible = try store.candidatesForTopic(id: topicId)
        #expect(Set(visible.map(\.videoId)) == Set(["keep", "opened"]))
    }

    @Test("excluded creators can be listed and restored")
    func excludedCreatorsRoundTrip() throws {
        let store = try TopicStore(inMemory: true)

        try store.excludeChannel(channelId: "chan-alpha", channelName: "Alpha Channel", iconUrl: "https://example.com/a.png", reason: "watch_feedback")
        #expect(try store.isChannelExcluded("chan-alpha") == true)

        let excluded = try store.excludedChannelsList()
        #expect(excluded.count == 1)
        #expect(excluded[0].channelId == "chan-alpha")
        #expect(excluded[0].channelName == "Alpha Channel")

        try store.restoreExcludedChannel(channelId: "chan-alpha")
        #expect(try store.isChannelExcluded("chan-alpha") == false)
        #expect(try store.excludedChannelsList().isEmpty)
    }

    @Test("favorite channels round-trip: insert, list, check, delete")
    func favoriteChannelsRoundTrip() throws {
        let store = try TopicStore(inMemory: true)

        #expect(try store.isChannelFavorite("chan-alpha") == false)
        #expect(try store.favoriteChannelsList().isEmpty)
        #expect(try store.favoriteChannelIDs().isEmpty)

        try store.favoriteChannel(
            channelId: "chan-alpha",
            channelName: "Alpha Channel",
            iconUrl: "https://example.com/a.png"
        )
        #expect(try store.isChannelFavorite("chan-alpha") == true)
        #expect(try store.favoriteChannelIDs() == Set(["chan-alpha"]))

        let favorites = try store.favoriteChannelsList()
        #expect(favorites.count == 1)
        #expect(favorites[0].channelId == "chan-alpha")
        #expect(favorites[0].channelName == "Alpha Channel")
        #expect(favorites[0].iconUrl == "https://example.com/a.png")
        #expect(favorites[0].notes == nil)

        try store.unfavoriteChannel(channelId: "chan-alpha")
        #expect(try store.isChannelFavorite("chan-alpha") == false)
        #expect(try store.favoriteChannelsList().isEmpty)
    }

    @Test("favorite channels are upserted on duplicate insert")
    func favoriteChannelsUpsert() throws {
        let store = try TopicStore(inMemory: true)

        try store.favoriteChannel(
            channelId: "chan-alpha",
            channelName: "Alpha Channel",
            iconUrl: "https://example.com/old.png"
        )
        // Second favorite call updates the icon URL.
        try store.favoriteChannel(
            channelId: "chan-alpha",
            channelName: "Alpha Channel",
            iconUrl: "https://example.com/new.png"
        )

        let favorites = try store.favoriteChannelsList()
        #expect(favorites.count == 1)
        #expect(favorites[0].iconUrl == "https://example.com/new.png")
    }

    @Test("favorite channels can store and update notes")
    func favoriteChannelsNotes() throws {
        let store = try TopicStore(inMemory: true)

        try store.favoriteChannel(
            channelId: "chan-alpha",
            channelName: "Alpha Channel",
            notes: "great keyboard reviews"
        )
        let initial = try store.favoriteChannelsList()
        #expect(initial[0].notes == "great keyboard reviews")

        try store.updateFavoriteChannelNotes(channelId: "chan-alpha", notes: "great keyboard and switch reviews")
        let updated = try store.favoriteChannelsList()
        #expect(updated[0].notes == "great keyboard and switch reviews")

        try store.updateFavoriteChannelNotes(channelId: "chan-alpha", notes: nil)
        let cleared = try store.favoriteChannelsList()
        #expect(cleared[0].notes == nil)
    }

    @Test("favorite channels list orders most-recently favorited first")
    func favoriteChannelsOrdering() throws {
        let store = try TopicStore(inMemory: true)

        try store.favoriteChannel(channelId: "chan-alpha", channelName: "Alpha")
        // Tiny sleep so the ISO8601 timestamps differ at second resolution.
        Thread.sleep(forTimeInterval: 1.05)
        try store.favoriteChannel(channelId: "chan-beta", channelName: "Beta")

        let favorites = try store.favoriteChannelsList()
        #expect(favorites.map(\.channelId) == ["chan-beta", "chan-alpha"])
    }

    @Test("favorite and exclude live in independent tables")
    func favoriteAndExcludeAreIndependent() throws {
        let store = try TopicStore(inMemory: true)

        try store.excludeChannel(channelId: "chan-alpha", channelName: "Alpha Channel")
        try store.favoriteChannel(channelId: "chan-alpha", channelName: "Alpha Channel")

        // Both states can coexist for the same channel — the user can favorite a creator
        // they previously excluded; the app's behavior is governed by which list it consults.
        #expect(try store.isChannelExcluded("chan-alpha") == true)
        #expect(try store.isChannelFavorite("chan-alpha") == true)

        try store.unfavoriteChannel(channelId: "chan-alpha")
        #expect(try store.isChannelExcluded("chan-alpha") == true)
        #expect(try store.isChannelFavorite("chan-alpha") == false)
    }

    // MARK: - Creator themes (LLM cache)

    @Test("creator themes round-trip: replace, fetch ordered, delete")
    func creatorThemesRoundTrip() throws {
        let store = try TopicStore(inMemory: true)

        let themes = [
            CreatorThemeRecord(
                channelId: "chan-x",
                label: "Switch Reviews",
                description: "Switches",
                order: 0,
                videoIds: ["v1", "v2"],
                isSeries: false,
                orderingSignal: nil,
                classifiedAt: "2026-04-10T00:00:00Z",
                classifiedVideoCount: 50
            ),
            CreatorThemeRecord(
                channelId: "chan-x",
                label: "Day Vlog",
                description: "Build vlog",
                order: 1,
                videoIds: ["v3", "v4", "v5"],
                isSeries: true,
                orderingSignal: "numeric",
                classifiedAt: "2026-04-10T00:00:00Z",
                classifiedVideoCount: 50
            )
        ]

        try store.replaceCreatorThemes(channelId: "chan-x", themes: themes)

        let fetched = try store.creatorThemes(channelId: "chan-x")
        #expect(fetched.count == 2)
        #expect(fetched[0].label == "Switch Reviews")
        #expect(fetched[0].videoIds == ["v1", "v2"])
        #expect(fetched[0].isSeries == false)
        #expect(fetched[1].label == "Day Vlog")
        #expect(fetched[1].videoIds == ["v3", "v4", "v5"])
        #expect(fetched[1].isSeries == true)
        #expect(fetched[1].orderingSignal == "numeric")

        try store.deleteCreatorThemes(channelId: "chan-x")
        #expect(try store.creatorThemes(channelId: "chan-x").isEmpty)
    }

    @Test("creator themes replace overwrites existing rows for the same channel")
    func creatorThemesReplaceOverwrites() throws {
        let store = try TopicStore(inMemory: true)

        let original = [
            CreatorThemeRecord(
                channelId: "chan-x", label: "Old", description: nil, order: 0,
                videoIds: ["v1"], isSeries: false, orderingSignal: nil,
                classifiedAt: "2026-01-01T00:00:00Z", classifiedVideoCount: 1
            )
        ]
        try store.replaceCreatorThemes(channelId: "chan-x", themes: original)
        #expect(try store.creatorThemes(channelId: "chan-x").count == 1)

        let updated = [
            CreatorThemeRecord(
                channelId: "chan-x", label: "New A", description: nil, order: 0,
                videoIds: ["v2"], isSeries: false, orderingSignal: nil,
                classifiedAt: "2026-04-10T00:00:00Z", classifiedVideoCount: 5
            ),
            CreatorThemeRecord(
                channelId: "chan-x", label: "New B", description: nil, order: 1,
                videoIds: ["v3"], isSeries: false, orderingSignal: nil,
                classifiedAt: "2026-04-10T00:00:00Z", classifiedVideoCount: 5
            )
        ]
        try store.replaceCreatorThemes(channelId: "chan-x", themes: updated)
        let fetched = try store.creatorThemes(channelId: "chan-x")
        #expect(fetched.count == 2)
        #expect(fetched.map(\.label) == ["New A", "New B"])
    }

    @Test("creator themes are isolated per channel")
    func creatorThemesIsolatedPerChannel() throws {
        let store = try TopicStore(inMemory: true)

        try store.replaceCreatorThemes(channelId: "chan-a", themes: [
            CreatorThemeRecord(
                channelId: "chan-a", label: "A theme", description: nil, order: 0,
                videoIds: ["v1"], isSeries: false, orderingSignal: nil,
                classifiedAt: "2026-04-10T00:00:00Z", classifiedVideoCount: 1
            )
        ])
        try store.replaceCreatorThemes(channelId: "chan-b", themes: [
            CreatorThemeRecord(
                channelId: "chan-b", label: "B theme", description: nil, order: 0,
                videoIds: ["v2"], isSeries: false, orderingSignal: nil,
                classifiedAt: "2026-04-10T00:00:00Z", classifiedVideoCount: 1
            )
        ])

        #expect(try store.creatorThemes(channelId: "chan-a").map(\.label) == ["A theme"])
        #expect(try store.creatorThemes(channelId: "chan-b").map(\.label) == ["B theme"])
    }

    // MARK: - Creator about (LLM cache)

    @Test("creator about round-trip: upsert, fetch, delete")
    func creatorAboutRoundTrip() throws {
        let store = try TopicStore(inMemory: true)

        #expect(try store.creatorAbout(channelId: "chan-x") == nil)

        let record = CreatorAboutRecord(
            channelId: "chan-x",
            summary: "This creator builds custom mechanical keyboards.",
            generatedAt: "2026-04-10T00:00:00Z",
            sourceVideoCount: 75
        )
        try store.upsertCreatorAbout(record)

        let fetched = try store.creatorAbout(channelId: "chan-x")
        #expect(fetched?.summary == "This creator builds custom mechanical keyboards.")
        #expect(fetched?.sourceVideoCount == 75)

        try store.deleteCreatorAbout(channelId: "chan-x")
        #expect(try store.creatorAbout(channelId: "chan-x") == nil)
    }

    @Test("creator about upsert replaces an existing row")
    func creatorAboutUpsertReplaces() throws {
        let store = try TopicStore(inMemory: true)

        try store.upsertCreatorAbout(CreatorAboutRecord(
            channelId: "chan-x", summary: "old summary",
            generatedAt: "2026-01-01T00:00:00Z", sourceVideoCount: 10
        ))
        try store.upsertCreatorAbout(CreatorAboutRecord(
            channelId: "chan-x", summary: "new summary",
            generatedAt: "2026-04-10T00:00:00Z", sourceVideoCount: 80
        ))

        let fetched = try store.creatorAbout(channelId: "chan-x")
        #expect(fetched?.summary == "new summary")
        #expect(fetched?.sourceVideoCount == 80)
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
