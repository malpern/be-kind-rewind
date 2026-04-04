import Foundation
import Testing
@testable import VideoOrganizer
@testable import TaggingKit

@Suite("OrganizerStore")
struct OrganizerStoreTests {
    @Test("loadTopics selects the first topic and exposes channel caches")
    @MainActor
    func loadTopicsBuildsInitialState() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)

            #expect(store.totalVideoCount == 4)
            #expect(store.unassignedCount == 1)
            #expect(store.selectedTopicId == store.topics.first?.id)
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))
            #expect(store.channelsForTopic(alphaTopic.id).map(\.channelId) == ["chan-alpha"])
            #expect(store.videoCountForChannel("chan-alpha", inTopic: alphaTopic.id) == 2)
            #expect(store.channelHasRecentContent("chan-alpha", inTopic: alphaTopic.id))
        }
    }

    @Test("changing selected topic clears selected channel filter")
    @MainActor
    func selectedTopicChangeClearsChannelFilter() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))
            let betaTopic = try #require(store.topics.first(where: { $0.name == "Beta Topic" }))

            store.selectedTopicId = alphaTopic.id
            store.selectedChannelId = "chan-alpha"
            store.inspectedCreatorName = "Alpha Channel"
            store.selectedTopicId = betaTopic.id

            #expect(store.selectedChannelId == nil)
            #expect(store.inspectedCreatorName == nil)
        }
    }

    @Test("selecting a video exits creator inspection")
    @MainActor
    func selectingVideoClearsCreatorInspection() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)

            store.inspectedCreatorName = "Alpha Channel"
            store.selectedVideoId = "vid-0"

            #expect(store.inspectedCreatorName == nil)
        }
    }

    @Test("playlist filter state is applied and cleared consistently")
    @MainActor
    func playlistFiltering() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let playlist = try #require(store.playlistsForVideo("vid-0").first)

            store.applyPlaylistFilter(playlist)
            #expect(store.selectedPlaylistId == "PL-ALPHA")
            #expect(store.selectedPlaylistTitle == "Alpha Favorites")
            #expect(store.videoIsInSelectedPlaylist("vid-0"))
            #expect(store.videoIsInSelectedPlaylist("vid-2") == false)

            store.clearPlaylistFilter()
            #expect(store.selectedPlaylistId == nil)
            #expect(store.selectedPlaylistTitle == nil)
            #expect(store.videoIsInSelectedPlaylist("vid-2"))
        }
    }

    @Test("typeahead suggestions include topics subtopics and channels sorted by count")
    @MainActor
    func typeaheadSuggestions() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            store.searchText = "alpha"

            let suggestions = store.typeaheadSuggestions()

            #expect(suggestions.map(\.text).contains("Alpha Topic"))
            #expect(suggestions.map(\.text).contains("Alpha Subtopic"))
            #expect(suggestions.map(\.text).contains("Alpha Channel"))
            #expect(suggestions.first?.count == 2)
        }
    }

    @Test("creator detail aggregates views ages and coverage")
    @MainActor
    func creatorDetailAggregation() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let detail = store.creatorDetail(channelName: "Alpha Channel")

            #expect(detail.totalVideoCount == 2)
            #expect(detail.totalViews == 1_540_000)
            #expect(detail.formattedViews == "1.5M views")
            #expect(detail.formattedSubscribers == "150K subscribers")
            #expect(detail.subscriberTier == "mid-tier creator")
            #expect(detail.newestAge == "today")
            #expect(detail.oldestAge == "10 days ago")
            #expect(detail.recentCount == 2)
            #expect(detail.coverageText == "You've saved 2 of 10 videos (20%)")
            #expect(detail.velocityText == "2 new videos in last 30 days")
            #expect(detail.videosByTopic.map(\.topicName) == ["Alpha Topic"])
        }
    }

    @Test("channel filter toggles on and off")
    @MainActor
    func toggleChannelFilter() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)

            store.toggleChannelFilter("chan-alpha")
            #expect(store.selectedChannelId == "chan-alpha")

            store.toggleChannelFilter("chan-alpha")
            #expect(store.selectedChannelId == nil)
        }
    }

    @Test("moreFromChannel excludes the current video and respects the limit")
    @MainActor
    func moreFromChannelExcludesCurrentVideo() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let related = store.moreFromChannel(videoId: "vid-0", limit: 5)

            #expect(related.map(\.videoId) == ["vid-1"])
        }
    }

    @Test("typeahead ignores short queries and exclude prefixes")
    @MainActor
    func typeaheadIgnoresShortAndExcludeQueries() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)

            store.searchText = "a"
            #expect(store.typeaheadSuggestions().isEmpty)

            store.searchText = "-alpha"
            #expect(store.typeaheadSuggestions().isEmpty)
        }
    }

    @Test("candidate progress copy defaults to idle state")
    @MainActor
    func candidateProgressText() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))

            #expect(store.candidateProgress(for: alphaTopic.id) == 0)
            #expect(store.candidateProgressTitle(for: alphaTopic.id) == "Finding candidates for this topic")
            #expect(store.candidateProgressDetail(for: alphaTopic.id) == "Preparing cached archives, adjacent creators, and candidate ranking.")
            #expect(store.candidateProgressOverlay == nil)
        }
    }

    @Test("setDisplayMode clears selection state when entering watch candidates")
    @MainActor
    func setDisplayModeClearsSelectionState() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))

            store.selectedTopicId = alphaTopic.id
            store.selectedChannelId = "chan-alpha"
            store.selectedSubtopicId = alphaTopic.subtopics.first?.id
            store.selectedVideoId = "vid-0"

            store.setDisplayMode(.watchCandidates, for: alphaTopic.id)

            #expect(store.displayMode(for: alphaTopic.id) == .watchCandidates)
            #expect(store.selectedChannelId == nil)
            #expect(store.selectedSubtopicId == nil)
            #expect(store.selectedVideoId == nil)
            #expect(store.selectedTopicId == alphaTopic.id)
        }
    }

    @Test("activateDisplayMode for saved mode bumps refresh token")
    @MainActor
    func activateDisplayModeSavedRefreshesToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbPath = directory.appendingPathComponent("organizer.db").path
        try makeOrganizerStoreFixture(at: dbPath)

        let store = try OrganizerStore(dbPath: dbPath)
        let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))
        let before = store.candidateRefreshToken

        await store.activateDisplayMode(.saved, for: alphaTopic.id)

        #expect(store.displayMode(for: alphaTopic.id) == .saved)
        #expect(store.candidateRefreshToken == before + 1)
    }

    @Test("watch later badge takes precedence for saved candidates")
    @MainActor
    func watchLaterBadgeForCandidate() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let fixtureStore = try TopicStore(path: dbPath)
            let alphaTopic = try fixtureStore.topicIdByName("Alpha Topic").unsafelyUnwrapped
            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "vid-3", title: "Gamma Debugging", channelId: "chan-gamma", channelName: "Gamma Channel", videoUrl: nil, viewCount: nil, publishedAt: nil, duration: nil, channelIconUrl: nil, score: 10, reason: "adjacent creator", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )
            try fixtureStore.upsertPlaylist(PlaylistRecord(playlistId: "WL", title: "Watch Later", visibility: "Private", videoCount: nil, source: "test", fetchedAt: "2026-04-04T00:00:00Z"))
            try fixtureStore.addPlaylistMembership(PlaylistMembershipRecord(playlistId: "WL", videoId: "vid-3", position: nil, verifiedAt: "2026-04-04T00:00:00Z"))
            try fixtureStore.setCandidateState(topicId: alphaTopic, videoId: "vid-3", state: .saved)

            let store = try OrganizerStore(dbPath: dbPath)

            let candidates = store.candidateVideosForTopic(alphaTopic)
            #expect(candidates.map(\.videoId) == ["vid-3"])
            #expect(store.badgeTagForVideo("vid-3", candidateState: CandidateState.saved.rawValue) == "Watch Later")
        }
    }

    @Test("renameTopic updates the topic list")
    @MainActor
    func renameTopicMutation() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))

            store.renameTopic(alphaTopic.id, to: "Renamed Topic")

            #expect(store.topics.contains(where: { $0.name == "Renamed Topic" }))
        }
    }

    @Test("deleteTopic clears selection when deleting the selected topic")
    @MainActor
    func deleteTopicMutation() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let betaTopic = try #require(store.topics.first(where: { $0.name == "Beta Topic" }))
            store.selectedTopicId = betaTopic.id

            store.deleteTopic(betaTopic.id)

            #expect(store.topics.contains(where: { $0.id == betaTopic.id }) == false)
            #expect(store.selectedTopicId != betaTopic.id)
        }
    }

    @Test("mergeTopics moves selection to the destination topic")
    @MainActor
    func mergeTopicsMutation() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))
            let betaTopic = try #require(store.topics.first(where: { $0.name == "Beta Topic" }))
            store.selectedTopicId = betaTopic.id

            store.mergeTopics(sourceId: betaTopic.id, intoId: alphaTopic.id)

            #expect(store.selectedTopicId == alphaTopic.id)
            #expect(store.topics.contains(where: { $0.id == betaTopic.id }) == false)
        }
    }

    @Test("moveVideo and moveVideos update topic membership")
    @MainActor
    func moveVideoMutations() throws {
        try withTemporaryDirectory { directory in
            let dbPath = directory.appendingPathComponent("organizer.db").path
            try makeOrganizerStoreFixture(at: dbPath)

            let store = try OrganizerStore(dbPath: dbPath)
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))
            let betaTopic = try #require(store.topics.first(where: { $0.name == "Beta Topic" }))

            store.moveVideo(videoId: "vid-2", toTopicId: alphaTopic.id)
            #expect(store.topicNameForVideo("vid-2") == "Alpha Topic")

            store.selectedVideoId = "vid-0"
            store.moveVideos(videoIds: ["vid-0", "vid-1"], toTopicId: betaTopic.id)
            #expect(store.selectedVideoId == nil)
            #expect(store.topicNameForVideo("vid-0") == "Beta Topic")
            #expect(store.topicNameForVideo("vid-1") == "Beta Topic")
        }
    }
}
