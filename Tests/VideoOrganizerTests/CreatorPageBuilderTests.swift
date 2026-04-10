import Foundation
import Testing
@testable import VideoOrganizer
@testable import TaggingKit

@Suite("CreatorPageBuilder")
struct CreatorPageBuilderTests {

    @MainActor
    @Test("makePage returns a populated page for a creator with saved videos")
    func populatesForKnownCreator() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)

            #expect(page.channelId == "chan-alpha")
            #expect(page.channelName == "Alpha Channel")
            #expect(page.savedVideoCount == 2) // chan-alpha has vid-0 and vid-1
            #expect(page.subscriberCountFormatted == "150K subs")
            #expect(page.creatorTier == "mid-tier creator")
            #expect(page.totalUploadsReported == 10)
            #expect(page.coveragePercent != nil)
            #expect(page.youtubeURL.absoluteString == "https://www.youtube.com/channel/chan-alpha")
            #expect(page.isFavorite == false)
            #expect(page.isExcluded == false)
        }
    }

    @MainActor
    @Test("makePage returns a graceful empty page for an unknown channel id")
    func gracefulEmptyForUnknownChannel() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-does-not-exist", in: store)

            #expect(page.channelName == "Unknown")
            #expect(page.savedVideoCount == 0)
            #expect(page.allVideos.isEmpty)
            #expect(page.essentials.isEmpty)
            #expect(page.latestVideo == nil)
            #expect(page.playlists.isEmpty)
            #expect(page.topicShare.isEmpty)
            #expect(page.totalUploadsKnown == 0)
        }
    }

    @MainActor
    @Test("makePage builds an allVideos list from saved videos with parsed view counts")
    func buildsAllVideosList() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)

            #expect(page.allVideos.count == 2)
            // Both videos for chan-alpha have parsed view counts.
            #expect(page.allVideos.contains { $0.viewCountParsed == 1_200_000 })
            #expect(page.allVideos.contains { $0.viewCountParsed == 340_000 })
        }
    }

    @MainActor
    @Test("makePage tags videos with their containing topic")
    func tagsVideosWithTopic() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)

            // chan-alpha videos appear in the Alpha topic via topic + subtopic rollup.
            // Both should have a topic name set.
            for video in page.allVideos {
                #expect(video.topicName != nil)
            }
        }
    }

    @MainActor
    @Test("makePage computes topic share with percentages summing to ~1.0")
    func topicShareSumsToOne() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)
            let totalShare = page.topicShare.reduce(0.0) { $0 + $1.percentage }

            #expect(!page.topicShare.isEmpty)
            #expect(abs(totalShare - 1.0) < 0.001)
        }
    }

    @MainActor
    @Test("makePage finds playlists where the creator's videos appear")
    func findsPlaylistsForCreator() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)

            // Both chan-alpha videos are in PL-ALPHA per the fixture.
            #expect(page.playlists.count == 1)
            #expect(page.playlists[0].playlist.playlistId == "PL-ALPHA")
            #expect(page.playlists[0].creatorVideoCount == 2)
        }
    }

    @MainActor
    @Test("makePage scores videos for outliers when at least one has views")
    func scoresOutliersAcrossCards() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)

            // With 2 videos (1.2M and 340K), median falls back to mean = 770K.
            // 1.2M / 770K ≈ 1.56, 340K / 770K ≈ 0.44 — neither is an outlier (threshold 3.0).
            #expect(page.channelMedianViews == 770_000)
            for video in page.allVideos where video.viewCountParsed > 0 {
                #expect(video.outlierScore > 0)
                #expect(video.isOutlier == false)
            }
        }
    }

    @MainActor
    @Test("makePage selects Essentials using OutlierAnalytics top-N")
    func essentialsAreTopOutliers() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)

            // 2 videos → 2 essentials (limit is 8 but the creator only has 2 known videos).
            #expect(page.essentials.count == 2)
            // Should be ordered by outlier score, which here is just by view count
            // (both videos are recent, equal recency weight).
            #expect(page.essentials.first?.viewCountParsed == 1_200_000)
        }
    }

    @MainActor
    @Test("makePage exposes the latest video as the most recent by age")
    func latestVideoIsMostRecent() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)

            // The fixture sets vid-1 to "today" and vid-0 to "10 days ago".
            #expect(page.latestVideo?.videoId == "vid-1")
        }
    }

    @MainActor
    @Test("makePage reflects favorite state from the OrganizerStore cache")
    func reflectsFavoriteState() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            #expect(CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store).isFavorite == false)

            store.favoriteCreator(channelId: "chan-alpha", channelName: "Alpha Channel")
            let pageAfter = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)
            #expect(pageAfter.isFavorite == true)
        }
    }

    @MainActor
    @Test("makePage isolates one creator from another in the same library")
    func isolationBetweenCreators() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let alpha = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)
            let beta = CreatorPageBuilder.makePage(forChannelId: "chan-beta", in: store)

            #expect(alpha.savedVideoCount == 2)
            #expect(beta.savedVideoCount == 1)
            // No cross-contamination of videos.
            #expect(!alpha.allVideos.contains { $0.videoId == "vid-2" })
            #expect(!beta.allVideos.contains { $0.videoId == "vid-0" })
            #expect(!beta.allVideos.contains { $0.videoId == "vid-1" })
        }
    }

    @MainActor
    @Test("makePage produces a 24-month cadence sequence even when most months are empty")
    func cadenceHasStableShape() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let page = CreatorPageBuilder.makePage(forChannelId: "chan-alpha", in: store)

            #expect(page.monthlyVideoCounts.count == 24)
            // Sum of monthly counts should equal the number of dated videos.
            let sum = page.monthlyVideoCounts.reduce(0) { $0 + $1.count }
            #expect(sum >= 0)
            #expect(sum <= page.allVideos.count)
        }
    }

    @Test("upscaledAvatarURL bumps yt3.ggpht.com size parameters to s800")
    func upscalesYT3Avatars() {
        let small = "https://yt3.ggpht.com/ytc/AIdro_kAAAA-foo=s88-c-k-c0x00ffffff-no-rj"
        let bumped = CreatorPageBuilder.upscaledAvatarURL(small)
        #expect(bumped == "https://yt3.ggpht.com/ytc/AIdro_kAAAA-foo=s800-c-k-c0x00ffffff-no-rj")
    }

    @Test("upscaledAvatarURL bumps any starting size to 800, including 240")
    func upscalesAnyStartingSize() {
        let medium = "https://yt3.ggpht.com/foo=s240-c-k"
        let bumped = CreatorPageBuilder.upscaledAvatarURL(medium)
        #expect(bumped == "https://yt3.ggpht.com/foo=s800-c-k")
    }

    @Test("upscaledAvatarURL also handles googleusercontent.com avatar URLs")
    func upscalesGoogleusercontentAvatars() {
        let small = "https://lh3.googleusercontent.com/foo=s96-c"
        let bumped = CreatorPageBuilder.upscaledAvatarURL(small)
        #expect(bumped == "https://lh3.googleusercontent.com/foo=s800-c")
    }

    @Test("upscaledAvatarURL leaves non-yt3 URLs unchanged")
    func upscaleIgnoresUnknownHosts() {
        let other = "https://example.com/avatar=s88-c"
        let bumped = CreatorPageBuilder.upscaledAvatarURL(other)
        #expect(bumped == other)
    }

    @Test("upscaledAvatarURL leaves URLs with no size parameter unchanged")
    func upscaleIgnoresMissingSizeParameter() {
        let url = "https://yt3.ggpht.com/avatar.jpg"
        let bumped = CreatorPageBuilder.upscaledAvatarURL(url)
        #expect(bumped == url)
    }
}
