import Foundation
import Testing
@testable import VideoOrganizer

@Suite("CreatorAnalytics — channelId migration")
struct CreatorAnalyticsChannelIdTests {

    @MainActor
    @Test("creatorDetail(channelId:) and creatorDetail(channelName:) return equivalent results for the same creator")
    func equivalenceWithLegacyVariant() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let byId = store.creatorDetail(channelId: "chan-alpha")
            let byName = store.creatorDetail(channelName: "Alpha Channel")

            #expect(byId.channelName == byName.channelName)
            #expect(byId.totalVideoCount == byName.totalVideoCount)
            #expect(byId.totalViews == byName.totalViews)
            #expect(byId.subscriberCount == byName.subscriberCount)
            #expect(byId.totalUploads == byName.totalUploads)
            #expect(byId.recentCount == byName.recentCount)
            // Topic groupings should match (both should walk the same topic list).
            #expect(byId.videosByTopic.map(\.topicName) == byName.videosByTopic.map(\.topicName))
        }
    }

    @MainActor
    @Test("creatorDetail(channelId:) finds videos for a creator with two videos across topic and subtopic")
    func findsVideosAcrossTopicAndSubtopic() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let detail = store.creatorDetail(channelId: "chan-alpha")

            #expect(detail.totalVideoCount == 2)
            #expect(detail.channelName == "Alpha Channel")
            // Both videos in chan-alpha are in the Alpha Topic tree (topic + subtopic),
            // which subtopic-rolls-up into the parent topic when listed via
            // videosForTopicIncludingSubtopics. Beta Channel videos must not appear.
            #expect(!detail.videosByTopic.flatMap(\.videos).contains { $0.channelId == "chan-beta" })
        }
    }

    @MainActor
    @Test("creatorDetail(channelId:) returns an empty result for an unknown channel id")
    func unknownChannelIdReturnsEmpty() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let detail = store.creatorDetail(channelId: "chan-does-not-exist")

            #expect(detail.totalVideoCount == 0)
            #expect(detail.totalViews == 0)
            #expect(detail.videosByTopic.isEmpty)
            // Unknown channel falls back to "Unknown" name when no record exists.
            #expect(detail.channelName == "Unknown")
        }
    }

    @MainActor
    @Test("creatorDetail(channelId:) resolves channel record metadata (subscriber count, total uploads, icon)")
    func resolvesChannelRecordMetadata() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let detail = store.creatorDetail(channelId: "chan-alpha")

            #expect(detail.subscriberCount == 150_000)
            #expect(detail.totalUploads == 10)
            #expect(detail.channelIconData == Data([1, 2, 3]))
        }
    }

    @MainActor
    @Test("creatorDetail(channelId:) computes total views by parsing fuzzy view counts")
    func computesTotalViews() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let detail = store.creatorDetail(channelId: "chan-alpha")

            // chan-alpha has vid-0 (1.2M views) + vid-1 (340K views) = 1,540,000
            #expect(detail.totalViews == 1_540_000)
        }
    }

    @MainActor
    @Test("creatorDetail(channelId:) is unaffected by another creator's videos in the same topic")
    func isolationFromOtherCreators() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let alpha = store.creatorDetail(channelId: "chan-alpha")
            let beta = store.creatorDetail(channelId: "chan-beta")

            #expect(alpha.totalVideoCount == 2)
            #expect(beta.totalVideoCount == 1)
            #expect(alpha.channelName == "Alpha Channel")
            #expect(beta.channelName == "Beta Channel")
        }
    }
}
