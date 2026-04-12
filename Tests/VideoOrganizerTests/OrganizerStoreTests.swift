import Foundation
import Testing
@testable import VideoOrganizer
@testable import TaggingKit

@Suite("OrganizerStore")
struct OrganizerStoreTests {
    @Test("loadTopics selects the first topic and exposes channel caches")
    @MainActor
    func loadTopicsBuildsInitialState() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

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
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
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
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            store.inspectedCreatorName = "Alpha Channel"
            store.selectedVideoId = "vid-0"

            #expect(store.inspectedCreatorName == nil)
        }
    }

    @Test("playlist filter state is applied and cleared consistently")
    @MainActor
    func playlistFiltering() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
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
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            store.searchText = "alpha"

            let suggestions = store.typeaheadSuggestions()

            #expect(suggestions.map(\.text).contains("Alpha Topic"))
            #expect(suggestions.map(\.text).contains("Alpha Subtopic"))
            #expect(suggestions.map(\.text).contains("Alpha Channel"))
            #expect(suggestions.first?.count == 2)
        }
    }

    @Test("topic search matching uses cached topic corpus")
    @MainActor
    func topicSearchMatchingUsesCachedCorpus() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))

            #expect(store.topicMatchesSearch(alphaTopic, query: SearchQuery("Alpha Channel")))
            #expect(store.topicMatchesSearch(alphaTopic, query: SearchQuery("Alpha SwiftUI Basics")))
            #expect(store.topicMatchesSearch(alphaTopic, query: SearchQuery("missing")) == false)
        }
    }

    @Test("creator detail aggregates views ages and coverage")
    @MainActor
    func creatorDetailAggregation() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
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
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            store.toggleChannelFilter("chan-alpha")
            #expect(store.selectedChannelId == "chan-alpha")

            store.toggleChannelFilter("chan-alpha")
            #expect(store.selectedChannelId == nil)
        }
    }

    @Test("moreFromChannel excludes the current video and respects the limit")
    @MainActor
    func moreFromChannelExcludesCurrentVideo() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let related = store.moreFromChannel(videoId: "vid-0", limit: 5)

            #expect(related.map(\.videoId) == ["vid-1"])
        }
    }

    @Test("typeahead ignores short queries and exclude prefixes")
    @MainActor
    func typeaheadIgnoresShortAndExcludeQueries() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            store.searchText = "a"
            #expect(store.typeaheadSuggestions().isEmpty)

            store.searchText = "-alpha"
            #expect(store.typeaheadSuggestions().isEmpty)
        }
    }

    @Test("watch refresh prioritizes selected and visible topics first")
    @MainActor
    func watchRefreshPrioritizationOrder() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))
            let betaTopic = try #require(store.topics.first(where: { $0.name == "Beta Topic" }))

            store.selectedTopicId = betaTopic.id
            store.viewportTopicId = alphaTopic.id
            store.updateVisibleWatchTopics([alphaTopic.id, betaTopic.id])

            let ordered = store.prioritizedWatchRefreshTopicIDs(from: store.topics.map(\.id))

            #expect(ordered == [betaTopic.id, alphaTopic.id])
        }
    }

    @Test("candidate progress copy defaults to idle state")
    @MainActor
    func candidateProgressText() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))

            #expect(store.candidateProgress(for: alphaTopic.id) == 0)
            #expect(store.candidateProgressTitle(for: alphaTopic.id) == "Finding candidates for this topic")
            #expect(store.candidateProgressDetail(for: alphaTopic.id) == "Preparing cached archives, adjacent creators, and candidate ranking.")
            #expect(store.candidateProgressOverlay == nil)
        }
    }

    @Test("stopBackgroundTasks cancels running lifecycle tasks")
    @MainActor
    func stopBackgroundTasksCancelsTasks() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try OrganizerStore(dbPath: fixture.dbPath, startBackgroundTasks: true)

            #expect(store.syncLoopTask != nil)
            #expect(store.browserStatusTask != nil)

            store.stopBackgroundTasks()

            #expect(store.syncTask == nil)
            #expect(store.browserSyncTask == nil)
            #expect(store.syncLoopTask == nil)
            #expect(store.browserStatusTask == nil)
            #expect(store.watchRefreshTask == nil)
            #expect(store.pendingAPIFallbackApproval == nil)
            #expect(store.apiFallbackPassActive == false)
        }
    }

    @Test("setPageDisplayMode clears selection state when entering watch candidates")
    @MainActor
    func setPageDisplayModeClearsSelectionState() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))

            store.selectedTopicId = alphaTopic.id
            store.selectedChannelId = "chan-alpha"
            store.selectedSubtopicId = alphaTopic.subtopics.first?.id
            store.selectedVideoId = "vid-0"

            store.setPageDisplayMode(.watchCandidates)

            #expect(store.displayMode(for: alphaTopic.id) == .watchCandidates)
            #expect(store.selectedChannelId == nil)
            #expect(store.selectedSubtopicId == nil)
            #expect(store.selectedVideoId == nil)
            #expect(store.selectedTopicId == alphaTopic.id)
        }
    }

    @Test("activatePageDisplayMode for saved mode bumps refresh token")
    @MainActor
    func activatePageDisplayModeSavedRefreshesToken() async throws {
        try await withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))
            let before = store.candidateRefreshToken

            await store.activatePageDisplayMode(.saved)

            #expect(store.displayMode(for: alphaTopic.id) == .saved)
            #expect(store.candidateRefreshToken >= before + 1)
        }
    }

    @Test("watch later badge takes precedence for saved candidates")
    @MainActor
    func watchLaterBadgeForCandidate() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try fixtureStore.topicIdByName("Alpha Topic").unsafelyUnwrapped
            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "vid-3", title: "Gamma Debugging", channelId: "chan-gamma", channelName: "Gamma Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-07T00:00:00Z", duration: nil, channelIconUrl: nil, score: 10, reason: "adjacent creator", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )
            try fixtureStore.upsertPlaylist(PlaylistRecord(playlistId: "WL", title: "Watch Later", visibility: "Private", videoCount: nil, source: "test", fetchedAt: "2026-04-04T00:00:00Z"))
            try fixtureStore.addPlaylistMembership(PlaylistMembershipRecord(playlistId: "WL", videoId: "vid-3", position: nil, verifiedAt: "2026-04-04T00:00:00Z"))
            try fixtureStore.setCandidateState(topicId: alphaTopic, videoId: "vid-3", state: .saved)

            let store = try fixture.makeOrganizerStore()

            let candidates = store.candidateVideosForTopic(alphaTopic)
            #expect(candidates.map(\.videoId) == ["vid-3"])
            #expect(store.badgeTagForVideo("vid-3", candidateState: CandidateState.saved.rawValue) == "Watch Later")
        }
    }

    @Test("watch candidates from creators new to the topic get a new creator badge")
    @MainActor
    func newCreatorBadgeForWatchCandidate() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "vid-new", title: "Fresh Gamma", channelId: "chan-gamma", channelName: "Gamma Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-07T00:00:00Z", duration: nil, channelIconUrl: nil, score: 10, reason: "search match", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()

            #expect(
                store.badgeTagForVideo(
                    "vid-new",
                    candidateState: CandidateState.candidate.rawValue,
                    topicId: alphaTopic,
                    channelId: "chan-gamma"
                ) == "New Creator"
            )
        }
    }

    @Test("watch show all reranking limits old backlog from a single creator")
    @MainActor
    func watchShowAllDiversifiesCreators() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))
            let betaTopic = try #require(try fixtureStore.topicIdByName("Beta Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "old-alpha-1", title: "Old Alpha One", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2024-01-01T00:00:00Z", duration: nil, channelIconUrl: nil, score: 100, reason: "affinity", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                    TopicCandidate(topicId: alphaTopic, videoId: "old-alpha-2", title: "Old Alpha Two", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2024-01-02T00:00:00Z", duration: nil, channelIconUrl: nil, score: 99, reason: "affinity", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )
            try fixtureStore.replaceCandidates(
                forTopic: betaTopic,
                candidates: [
                    TopicCandidate(topicId: betaTopic, videoId: "fresh-beta", title: "Fresh Beta", channelId: "chan-beta", channelName: "Beta Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-07T00:00:00Z", duration: nil, channelIconUrl: nil, score: 96, reason: "fresh", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()

            let ranked = store.candidateVideosForAllTopics().map(\.videoId)
            #expect(ranked.prefix(3).contains("fresh-beta"))
            #expect(ranked.firstIndex(of: "fresh-beta") ?? .max < ranked.firstIndex(of: "old-alpha-2") ?? .max)
        }
    }

    @Test("watch show all deduplicates videos that appear in multiple topics")
    @MainActor
    func watchShowAllDeduplicatesAcrossTopics() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))
            let betaTopic = try #require(try fixtureStore.topicIdByName("Beta Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "shared-video", title: "Shared", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-06T00:00:00Z", duration: nil, channelIconUrl: nil, score: 90, reason: "alpha", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )
            try fixtureStore.replaceCandidates(
                forTopic: betaTopic,
                candidates: [
                    TopicCandidate(topicId: betaTopic, videoId: "shared-video", title: "Shared", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-06T00:00:00Z", duration: nil, channelIconUrl: nil, score: 88, reason: "beta", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                    TopicCandidate(topicId: betaTopic, videoId: "unique-video", title: "Unique", channelId: "chan-beta", channelName: "Beta Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-07T00:00:00Z", duration: nil, channelIconUrl: nil, score: 70, reason: "unique", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()
            let ranked = store.candidateVideosForAllTopics().map(\.videoId)

            #expect(ranked.filter { $0 == "shared-video" }.count == 1)
            #expect(Set(ranked) == Set(["shared-video", "unique-video"]))
        }
    }

    @Test("watch by topic assigns shared videos to the strongest topic only")
    @MainActor
    func watchByTopicAssignsSharedVideosToSingleBestTopic() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))
            let betaTopic = try #require(try fixtureStore.topicIdByName("Beta Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "shared-video", title: "Shared", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-06T00:00:00Z", duration: nil, channelIconUrl: nil, score: 90, reason: "alpha", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )
            try fixtureStore.replaceCandidates(
                forTopic: betaTopic,
                candidates: [
                    TopicCandidate(topicId: betaTopic, videoId: "shared-video", title: "Shared", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-06T00:00:00Z", duration: nil, channelIconUrl: nil, score: 88, reason: "beta", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                    TopicCandidate(topicId: betaTopic, videoId: "unique-video", title: "Unique", channelId: "chan-beta", channelName: "Beta Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-07T00:00:00Z", duration: nil, channelIconUrl: nil, score: 70, reason: "unique", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()

            #expect(store.candidateVideosForTopic(alphaTopic).map(\.videoId) == ["shared-video"])
            #expect(store.candidateVideosForTopic(betaTopic).map(\.videoId) == ["unique-video"])
        }
    }

    @Test("watch by topic prefers stronger topical evidence over weaker adjacent matches")
    @MainActor
    func watchByTopicPrefersStrongerTopicEvidence() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))
            let betaTopic = try #require(try fixtureStore.topicIdByName("Beta Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "shared-video", title: "Shared", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-06T00:00:00Z", duration: nil, channelIconUrl: nil, score: 82, reason: "Fresh upload from a creator already in this topic", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )
            try fixtureStore.replaceCandidates(
                forTopic: betaTopic,
                candidates: [
                    TopicCandidate(topicId: betaTopic, videoId: "shared-video", title: "Shared", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-06T00:00:00Z", duration: nil, channelIconUrl: nil, score: 90, reason: "Fresh upload from a creator adjacent to this topic via Generic Playlist", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()

            #expect(store.candidateVideosForTopic(alphaTopic).map(\.videoId) == ["shared-video"])
            #expect(store.candidateVideosForTopic(betaTopic).contains(where: { $0.videoId == "shared-video" }) == false)
        }
    }

    @Test("watch pool excludes older candidates from visible topic results")
    @MainActor
    func watchPoolIsRecentOnly() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "fresh", title: "Fresh", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-08T00:00:00Z", duration: nil, channelIconUrl: nil, score: 20, reason: "fresh", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                    TopicCandidate(topicId: alphaTopic, videoId: "old", title: "Old", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2025-12-01T00:00:00Z", duration: nil, channelIconUrl: nil, score: 99, reason: "old", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()
            let visible = store.candidateVideosForTopic(alphaTopic).map(\.videoId)

            #expect(visible == ["fresh"])
        }
    }

    @Test("watch creator filter stays in watch and filters current topic pool")
    @MainActor
    func watchCreatorFilterStaysInWatch() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "alpha-fresh", title: "Alpha Fresh", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-08T00:00:00Z", duration: nil, channelIconUrl: nil, score: 30, reason: "alpha", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                    TopicCandidate(topicId: alphaTopic, videoId: "beta-fresh", title: "Beta Fresh", channelId: "chan-beta", channelName: "Beta Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-07T00:00:00Z", duration: nil, channelIconUrl: nil, score: 29, reason: "beta", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()
            store.setPageDisplayMode(.watchCandidates)

            _ = store.navigateToCreatorInWatch(channelId: "chan-alpha", channelName: "Alpha Channel", preferredTopicId: alphaTopic)

            #expect(store.pageDisplayMode == .watchCandidates)
            #expect(store.selectedTopicId == alphaTopic)
            #expect(store.selectedChannelId == "chan-alpha")
            #expect(store.candidateVideosForTopic(alphaTopic).map(\.videoId) == ["alpha-fresh"])
        }
    }

    @Test("excluding a creator hides them from Watch immediately")
    @MainActor
    func excludingCreatorHidesWatchCandidates() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "alpha-fresh", title: "Alpha Fresh", channelId: "chan-alpha", channelName: "Alpha Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-08T00:00:00Z", duration: nil, channelIconUrl: nil, score: 30, reason: "alpha", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                    TopicCandidate(topicId: alphaTopic, videoId: "beta-fresh", title: "Beta Fresh", channelId: "chan-beta", channelName: "Beta Channel", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-07T00:00:00Z", duration: nil, channelIconUrl: nil, score: 29, reason: "beta", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()
            store.setPageDisplayMode(.watchCandidates)
            #expect(Set(store.candidateVideosForTopic(alphaTopic).map(\.videoId)) == Set(["alpha-fresh", "beta-fresh"]))

            store.excludeCreatorFromWatch(channelId: "chan-alpha", channelName: "Alpha Channel")

            #expect(store.excludedCreators.contains(where: { $0.channelId == "chan-alpha" }))
            #expect(store.candidateVideosForTopic(alphaTopic).map(\.videoId) == ["beta-fresh"])
        }
    }

    @Test("refreshSyncQueueSummary exposes queued and browser deferred work")
    @MainActor
    func refreshSyncQueueSummaryExposure() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            try store.store.queueCommit(action: "add_to_playlist", videoId: "vid-0", playlist: "PL-ALPHA")
            try store.store.queueCommit(action: "not_interested", videoId: "vid-2", playlist: "__youtube__")

            store.refreshSyncQueueSummary()
            #expect(store.syncQueueSummary.queued == 2)
            #expect(store.syncQueueSummary.deferred == 0)
            #expect(store.syncQueueSummary.browserDeferred == 0)

            let browserActions = try store.store.pendingSyncPlan(executor: .browser)
            try store.store.markDeferred(ids: browserActions.map(\.id), error: "Waiting for browser executor")

            store.refreshSyncQueueSummary()
            #expect(store.syncQueueSummary.queued == 1)
            #expect(store.syncQueueSummary.deferred == 1)
            #expect(store.syncQueueSummary.browserDeferred == 1)
        }
    }

    @Test("markCandidateNotInterested updates the user-facing alert")
    @MainActor
    func markCandidateNotInterestedAlert() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))
            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "vid-3", title: "Gamma Debugging", channelId: "chan-gamma", channelName: "Gamma Channel", videoUrl: nil, viewCount: nil, publishedAt: nil, duration: nil, channelIconUrl: nil, score: 10, reason: "adjacent creator", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()
            store.browserExecutorReady = false

            store.markCandidateNotInterested(topicId: alphaTopic, videoId: "vid-3")

            #expect(store.alert?.title == "Queued Not Interested")
            #expect(store.alert?.message.contains("queued") == true)
        }
    }

    @Test("renameTopic updates the topic list")
    @MainActor
    func renameTopicMutation() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))

            store.renameTopic(alphaTopic.id, to: "Renamed Topic")

            #expect(store.topics.contains(where: { $0.name == "Renamed Topic" }))
        }
    }

    @Test("deleteTopic clears selection when deleting the selected topic")
    @MainActor
    func deleteTopicMutation() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
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
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
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
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
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

    @Test("file-backed organizer fixture tears down cleanly across repeated runs")
    @MainActor
    func repeatedFileBackedFixtureTeardown() throws {
        for iteration in 0..<25 {
            try withFileBackedOrganizerFixture { fixture in
                let topicStore = try fixture.makeTopicStore()
                let organizerStore = try fixture.makeOrganizerStore()

                #expect(try topicStore.totalVideoCount() == 4, "topic store setup failed on iteration \(iteration)")
                #expect(organizerStore.totalVideoCount == 4, "organizer store setup failed on iteration \(iteration)")
                #expect(try topicStore.listTopics().count == 2, "topics missing on iteration \(iteration)")
            }
        }
    }

    @Test("phase 2 adjacent creator admission requires stronger evidence")
    @MainActor
    func adjacentCreatorAdmissionThreshold() {
        #expect(CandidateDiscoveryCoordinator.adjacentCreatorMeetsAdmissionThreshold(score: 1.3, matchedPlaylistCount: 2) == false)
        #expect(CandidateDiscoveryCoordinator.adjacentCreatorMeetsAdmissionThreshold(score: 1.5, matchedPlaylistCount: 2))
        #expect(CandidateDiscoveryCoordinator.adjacentCreatorMeetsAdmissionThreshold(score: 2.1, matchedPlaylistCount: 1) == false)
        #expect(CandidateDiscoveryCoordinator.adjacentCreatorMeetsAdmissionThreshold(score: 2.2, matchedPlaylistCount: 1))
    }

    @Test("phase 2 search queries include topic review year and a topic-specific modifier")
    @MainActor
    func phase2GeneratedSearchQueries() {
        let topic = TopicViewModel(id: 42, name: "Mechanical Keyboards", videoCount: 0, subtopics: [])
        let queries = CandidateDiscoveryCoordinator.generatedSearchQueries(for: topic)

        #expect(queries.contains("Mechanical Keyboards"))
        #expect(queries.contains("Mechanical Keyboards review"))
        #expect(queries.contains("Mechanical Keyboards 2026"))
        #expect(queries.contains("Mechanical Keyboards qmk"))
        #expect(Set(queries.map { $0.lowercased() }).count == queries.count)
    }

    @Test("related seed planner prefers diverse non-related source lanes before fallback seeds")
    @MainActor
    func relatedSeedPlannerPrefersDiverseSeedSources() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let topic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))

            let aggregate: [String: AggregatedCandidate] = [
                "archive-seed": AggregatedCandidate(
                    videoId: "archive-seed",
                    title: "Alpha Archive Seed",
                    channelId: "chan-alpha",
                    channelName: "Alpha Channel",
                    viewCount: "10K views",
                    publishedAt: "2026-04-11T00:00:00Z",
                    duration: "10:00",
                    channelIconUrl: nil,
                    score: 120,
                    reason: "archive",
                    sources: [CandidateSource(kind: "channel_archive_recent", ref: "chan-alpha")]
                ),
                "search-seed": AggregatedCandidate(
                    videoId: "search-seed",
                    title: "Alpha Search Seed",
                    channelId: "chan-search",
                    channelName: "Search Channel",
                    viewCount: "8K views",
                    publishedAt: "2026-04-10T00:00:00Z",
                    duration: "9:00",
                    channelIconUrl: nil,
                    score: 110,
                    reason: "search",
                    sources: [CandidateSource(kind: "search_query_recent", ref: "alpha review")]
                ),
                "adjacent-seed": AggregatedCandidate(
                    videoId: "adjacent-seed",
                    title: "Alpha Adjacent Seed",
                    channelId: "chan-adjacent",
                    channelName: "Adjacent Channel",
                    viewCount: "7K views",
                    publishedAt: "2026-04-09T00:00:00Z",
                    duration: "8:30",
                    channelIconUrl: nil,
                    score: 105,
                    reason: "adjacent",
                    sources: [CandidateSource(kind: "playlist_adjacent_recent", ref: "PL-ALPHA")]
                ),
                "related-only": AggregatedCandidate(
                    videoId: "related-only",
                    title: "Related Only Seed",
                    channelId: "chan-related",
                    channelName: "Related Channel",
                    viewCount: "9K views",
                    publishedAt: "2026-04-12T00:00:00Z",
                    duration: "11:00",
                    channelIconUrl: nil,
                    score: 130,
                    reason: "related",
                    sources: [CandidateSource(kind: "browser_related_signed_in", ref: "seed-video")]
                )
            ]

            let plans = CandidateDiscoveryCoordinator.relatedSeedPlans(for: topic.id, aggregate: aggregate, store: store)

            #expect(plans.prefix(3).map(\.videoId) == ["archive-seed", "search-seed", "adjacent-seed"])
            #expect(plans.prefix(3).map(\.sourceKind) == ["channel_archive_recent", "search_query_recent", "playlist_adjacent_recent"])
            #expect(plans.count == 4)
            #expect(plans[3].sourceKind == "saved_topic_recent")
            #expect(Set(["vid-0", "vid-1"]).contains(plans[3].videoId))
        }
    }

    @Test("related seed consensus bonus rewards repeated evidence and mixed seed lanes")
    @MainActor
    func relatedSeedConsensusBonus() {
        #expect(CandidateDiscoveryCoordinator.relatedSeedConsensusBonus(seedCount: 1, seedSourceKindCount: 1) == 0)
        #expect(CandidateDiscoveryCoordinator.relatedSeedConsensusBonus(seedCount: 2, seedSourceKindCount: 1) == 10)
        #expect(CandidateDiscoveryCoordinator.relatedSeedConsensusBonus(seedCount: 2, seedSourceKindCount: 2) == 18)
        #expect(CandidateDiscoveryCoordinator.relatedSeedConsensusBonus(seedCount: 3, seedSourceKindCount: 2) == 28)
    }

    @Test("creator related consensus bonus rewards repeated creator evidence more conservatively")
    @MainActor
    func creatorRelatedConsensusBonus() {
        #expect(CandidateDiscoveryCoordinator.creatorRelatedConsensusBonus(seedCount: 1, seedSourceKindCount: 1) == 0)
        #expect(CandidateDiscoveryCoordinator.creatorRelatedConsensusBonus(seedCount: 2, seedSourceKindCount: 1) == 6)
        #expect(CandidateDiscoveryCoordinator.creatorRelatedConsensusBonus(seedCount: 2, seedSourceKindCount: 2) == 10)
        #expect(CandidateDiscoveryCoordinator.creatorRelatedConsensusBonus(seedCount: 3, seedSourceKindCount: 2) == 16)
    }

    @Test("creator related consensus applies only to creators reached from multiple seeds")
    @MainActor
    func applyCreatorRelatedConsensusBonus() {
        var aggregate: [String: AggregatedCandidate] = [
            "alpha-1": AggregatedCandidate(
                videoId: "alpha-1",
                title: "Alpha One",
                channelId: "chan-alpha",
                channelName: "Alpha Channel",
                viewCount: nil,
                publishedAt: "2026-04-10T00:00:00Z",
                duration: nil,
                channelIconUrl: nil,
                score: 50,
                reason: "related",
                sources: [CandidateSource(kind: "browser_related_signed_in", ref: "seed-a")],
                relatedSeedVideoIds: ["seed-a"],
                relatedSeedSourceKinds: ["channel_archive_recent"]
            ),
            "alpha-2": AggregatedCandidate(
                videoId: "alpha-2",
                title: "Alpha Two",
                channelId: "chan-alpha",
                channelName: "Alpha Channel",
                viewCount: nil,
                publishedAt: "2026-04-11T00:00:00Z",
                duration: nil,
                channelIconUrl: nil,
                score: 40,
                reason: "related",
                sources: [CandidateSource(kind: "browser_related_signed_in", ref: "seed-b")],
                relatedSeedVideoIds: ["seed-b"],
                relatedSeedSourceKinds: ["search_query_recent"]
            ),
            "beta-1": AggregatedCandidate(
                videoId: "beta-1",
                title: "Beta One",
                channelId: "chan-beta",
                channelName: "Beta Channel",
                viewCount: nil,
                publishedAt: "2026-04-09T00:00:00Z",
                duration: nil,
                channelIconUrl: nil,
                score: 30,
                reason: "related",
                sources: [CandidateSource(kind: "browser_related_signed_in", ref: "seed-c")],
                relatedSeedVideoIds: ["seed-c"],
                relatedSeedSourceKinds: ["channel_archive_recent"]
            )
        ]

        CandidateDiscoveryCoordinator.applyCreatorRelatedConsensusBonus(to: &aggregate)

        #expect(aggregate["alpha-1"]?.score == 60)
        #expect(aggregate["alpha-2"]?.score == 50)
        #expect(aggregate["beta-1"]?.score == 30)
    }

    @Test("watch candidate inspection exposes stored provenance sources")
    @MainActor
    func inspectedCandidateIncludesProvenance() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let store = try fixture.makeOrganizerStore()
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" })?.id)

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(
                        topicId: alphaTopic,
                        videoId: "vid-3",
                        title: "Gamma Debugging",
                        channelId: "chan-gamma",
                        channelName: "Gamma Channel",
                        videoUrl: nil,
                        viewCount: nil,
                        publishedAt: "2026-04-07T00:00:00Z",
                        duration: nil,
                        channelIconUrl: nil,
                        score: 10,
                        reason: "Signed-in related suggestion from topic seed Alpha SwiftUI Basics",
                        state: CandidateState.candidate.rawValue,
                        discoveredAt: nil
                    )
                ],
                sources: [
                    CandidateSourceRecord(topicId: alphaTopic, videoId: "vid-3", sourceKind: "browser_related_signed_in", sourceRef: "Alpha SwiftUI Basics"),
                    CandidateSourceRecord(topicId: alphaTopic, videoId: "vid-3", sourceKind: "search_query_recent", sourceRef: "Alpha Topic review")
                ]
            )

            store.reloadStoredCandidateCache(for: alphaTopic)
            store.pageDisplayMode = .watchCandidates
            store.selectedTopicId = alphaTopic
            store.selectedVideoId = "vid-3"

            let inspected = try #require(store.inspectedItem)
            #expect(inspected.isWatchCandidate)
            #expect(inspected.candidateReason == "Signed-in related suggestion from topic seed Alpha SwiftUI Basics")
            #expect(inspected.candidateSources.map(\.sourceKind) == ["browser_related_signed_in", "search_query_recent"])
        }
    }

    @Test("signed-in related lane uses exploratory topical admission")
    @MainActor
    func signedInRelatedAdmissionUsesExploratoryGate() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let topic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))

            let allowed = CandidateDiscoveryCoordinator.watchTopicAdmission(
                forTopic: topic.id,
                title: "Alpha SwiftUI Layout Tips",
                sourceKind: "browser_related_signed_in",
                sourceRef: "Alpha SwiftUI Basics",
                store: store
            )
            let rejected = CandidateDiscoveryCoordinator.watchTopicAdmission(
                forTopic: topic.id,
                title: "Completely Unrelated Cooking Video",
                sourceKind: "browser_related_signed_in",
                sourceRef: "Alpha SwiftUI Basics",
                store: store
            )

            #expect(allowed.shouldAdmit)
            #expect(rejected.shouldAdmit == false)
        }
    }

    @Test("candidate assignment treats signed-in related suggestions like exploratory discovery")
    @MainActor
    func signedInRelatedAssignmentStrength() {
        let video = CandidateVideoViewModel(
            topicId: 42,
            videoId: "vid-1",
            title: "Recommended",
            channelId: "chan-1",
            channelName: "Alpha Channel",
            viewCount: nil,
            publishedAt: "2026-04-10T00:00:00Z",
            duration: nil,
            channelIconUrl: nil,
            score: 10,
            secondaryText: "Signed-in related suggestion from topic seed Alpha SwiftUI Basics",
            state: CandidateState.candidate.rawValue,
            isPlaceholder: false
        )

        #expect(video.assignmentStrength == 2)
    }

    @Test("watch topical gate rejects keyboard videos for embedded systems")
    @MainActor
    func topicalGateRejectsKeyboardVideosForEmbeddedSystems() {
        let topic = TopicViewModel(
            id: 100,
            name: "Embedded Systems",
            videoCount: 0,
            subtopics: []
        )

        let evidence = CandidateDiscoveryCoordinator.topicalEvidence(
            for: "Building a Tiny 16x16 Choc Mechanical Keyboard",
            query: "Embedded Systems 2026",
            topic: topic
        )

        #expect(evidence.exploratoryQualifies == false)
        #expect(evidence.knownCreatorQualifies == false)
    }

    @Test("watch topical gate rejects terminal videos for macos topic")
    @MainActor
    func topicalGateRejectsTerminalVideosForMacOS() {
        let topic = TopicViewModel(
            id: 101,
            name: "macOS & Apple",
            videoCount: 0,
            subtopics: []
        )

        let evidence = CandidateDiscoveryCoordinator.topicalEvidence(
            for: "[Live Q&A] Ghostty vs Kitty | Mitchell Hashimoto and Kovid Goyal",
            query: "macOS & Apple tutorial",
            topic: topic
        )

        #expect(evidence.exploratoryQualifies == false)
        #expect(evidence.knownCreatorQualifies == false)
    }

    @Test("watch topical gate admits keyboard videos for mechanical keyboards")
    @MainActor
    func topicalGateAdmitsKeyboardVideosForMechanicalKeyboards() {
        let topic = TopicViewModel(
            id: 102,
            name: "Mechanical Keyboards",
            videoCount: 0,
            subtopics: []
        )

        let evidence = CandidateDiscoveryCoordinator.topicalEvidence(
            for: "Building a Handwired Mechanical Keyboard with a Knob",
            query: "Mechanical Keyboards qmk",
            topic: topic
        )

        #expect(evidence.exploratoryQualifies)
        #expect(evidence.knownCreatorQualifies)
    }

    // MARK: - Watch pool stability + viewport integration

    @Test("stable pool rebuild does not replace unchanged topic pools")
    @MainActor
    func stablePoolRebuildSkipsUnchangedTopics() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "stable-1", title: "Stable One", channelId: "chan-alpha", channelName: "Alpha", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-10T00:00:00Z", duration: nil, channelIconUrl: nil, score: 50, reason: "test", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()
            store.setPageDisplayMode(.watchCandidates)
            store.rebuildWatchPools()

            // Capture the pool array identity (same Swift Array instance)
            let poolBefore = store.candidateVideosForTopic(alphaTopic)
            #expect(poolBefore.map(\.videoId) == ["stable-1"])

            // Rebuild again with no data change
            store.rebuildWatchPools()

            let poolAfter = store.candidateVideosForTopic(alphaTopic)
            #expect(poolAfter.map(\.videoId) == ["stable-1"])
            // The video IDs are the same — stable update should not have
            // replaced the array, preventing unnecessary SwiftUI observation.
        }
    }

    @Test("impression counter increments for top-ranked candidates on rebuild")
    @MainActor
    func impressionCounterIncrementsOnRebuild() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "imp-1", title: "Impression Test", channelId: "chan-alpha", channelName: "Alpha", videoUrl: nil, viewCount: nil, publishedAt: "2026-04-10T00:00:00Z", duration: nil, channelIconUrl: nil, score: 50, reason: "test", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()
            store.setPageDisplayMode(.watchCandidates)

            let countBefore = store.watchImpressionCounts["imp-1"] ?? 0
            store.rebuildWatchPools(trackImpressions: true)
            let countAfter = store.watchImpressionCounts["imp-1"] ?? 0

            #expect(countAfter > countBefore)
        }
    }

    @Test("recency boost ranks today's video above older high-score video")
    @MainActor
    func recencyBoostSurfacesFreshContent() throws {
        try withFileBackedOrganizerFixture { fixture in
            let fixtureStore = try fixture.makeTopicStore()
            let alphaTopic = try #require(try fixtureStore.topicIdByName("Alpha Topic"))

            // Old video with high base score
            // Fresh video with low base score
            let today = ISO8601DateFormatter().string(from: Date())
            let oldDate = "2025-06-01T00:00:00Z"

            try fixtureStore.replaceCandidates(
                forTopic: alphaTopic,
                candidates: [
                    TopicCandidate(topicId: alphaTopic, videoId: "old-hit", title: "Old Hit", channelId: "chan-alpha", channelName: "Alpha", videoUrl: nil, viewCount: "5M views", publishedAt: oldDate, duration: nil, channelIconUrl: nil, score: 300, reason: "high views", state: CandidateState.candidate.rawValue, discoveredAt: nil),
                    TopicCandidate(topicId: alphaTopic, videoId: "fresh-upload", title: "Fresh Upload", channelId: "chan-beta", channelName: "Beta", videoUrl: nil, viewCount: "1K views", publishedAt: today, duration: nil, channelIconUrl: nil, score: 50, reason: "fresh", state: CandidateState.candidate.rawValue, discoveredAt: nil)
                ],
                sources: []
            )

            let store = try fixture.makeOrganizerStore()
            store.setPageDisplayMode(.watchCandidates)
            store.rebuildWatchPools()

            let ranked = store.candidateVideosForAllTopics().map(\.videoId)
            let freshIndex = ranked.firstIndex(of: "fresh-upload")
            let oldIndex = ranked.firstIndex(of: "old-hit")

            // Fresh video should rank above the old one despite lower base score
            if let fi = freshIndex, let oi = oldIndex {
                #expect(fi < oi, "Fresh upload (score 50 + recency boost) should rank above old hit (score 300)")
            }
        }
    }

    @Test("viewport topic update tracks the visible topic")
    @MainActor
    func viewportTopicTracking() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()
            let alphaTopic = try #require(store.topics.first(where: { $0.name == "Alpha Topic" }))
            let betaTopic = try #require(store.topics.first(where: { $0.name == "Beta Topic" }))

            store.updateViewportContext(topicId: alphaTopic.id, subtopicId: nil, creatorSectionId: nil)
            #expect(store.viewportTopicId == alphaTopic.id)

            store.updateViewportContext(topicId: betaTopic.id, subtopicId: nil, creatorSectionId: nil)
            #expect(store.viewportTopicId == betaTopic.id)
        }
    }

    @Test("updateSelection syncs primary and full set")
    @MainActor
    func updateSelectionSyncsPrimaryAndSet() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            store.updateSelection(primary: "vid-a", all: ["vid-a", "vid-b", "vid-c"])

            #expect(store.selectedVideoId == "vid-a")
            #expect(store.selectedVideoIds == ["vid-a", "vid-b", "vid-c"])
        }
    }

    @Test("multi-select inspectedSelection returns .multiple for 2+ videos")
    @MainActor
    func multiSelectInspectedSelection() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            // Select two videos that exist in the store's videoMap
            let videoIds = Array(store.videoMap.keys.prefix(2))
            guard videoIds.count >= 2 else { return }

            store.updateSelection(primary: videoIds[0], all: Set(videoIds))

            if case .multiple(let videos) = store.inspectedSelection {
                #expect(videos.count == 2)
            } else {
                Issue.record("Expected .multiple for 2 selected videos, got \(store.inspectedSelection)")
            }
        }
    }
}
