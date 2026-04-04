import Foundation
import Testing
@testable import VideoOrganizer

private func makeGridVideo(
    id: String,
    title: String,
    channelName: String?,
    viewCount: String? = nil,
    publishedAt: String? = nil,
    duration: String? = nil,
    channelIconURL: String? = nil,
    channelId: String? = nil
) -> VideoGridItemModel {
    VideoGridItemModel(
        id: id,
        title: title,
        channelName: channelName,
        topicName: nil,
        thumbnailUrl: nil,
        viewCount: viewCount,
        publishedAt: publishedAt,
        duration: duration,
        channelIconUrl: channelIconURL.flatMap(URL.init(string:)),
        channelId: channelId,
        candidateScore: nil,
        stateTag: nil,
        isPlaceholder: false,
        placeholderMessage: nil
    )
}

@Suite("GridSectionLogic")
struct GridSectionLogicTests {
    @Test("parses compact view counts age strings and durations")
    func parsesMetrics() {
        #expect(GridSectionLogic.parseViewCount("1.2M views") == 1_200_000)
        #expect(GridSectionLogic.parseViewCount("340K views") == 340_000)
        #expect(GridSectionLogic.parseViewCount("800 views") == 800)
        #expect(GridSectionLogic.parseAge("today") == 0)
        #expect(GridSectionLogic.parseAge("2 months ago") == 60)
        #expect(GridSectionLogic.parseAge("3 years ago") == 1_095)
        #expect(GridSectionLogic.parseDuration("1:02:03") == 3_723)
        #expect(GridSectionLogic.parseDuration("12:34") == 754)
    }

    @Test("sorts videos by views and date")
    func sortsVideos() {
        let videos = [
            makeGridVideo(id: "a", title: "A", channelName: "Alpha", viewCount: "800 views", publishedAt: "2 months ago"),
            makeGridVideo(id: "b", title: "B", channelName: "Beta", viewCount: "1.2M views", publishedAt: "today"),
            makeGridVideo(id: "c", title: "C", channelName: "Gamma", viewCount: "340K views", publishedAt: "10 days ago")
        ]

        let byViews = GridSectionLogic.sortVideos(videos, by: .views, ascending: false)
        let byDate = GridSectionLogic.sortVideos(videos, by: .date, ascending: false)

        #expect(byViews.map(\.id) == ["b", "c", "a"])
        #expect(byDate.map(\.id) == ["b", "c", "a"])
    }

    @Test("groups videos by creator and preserves newest-first ordering inside each creator")
    func groupsByCreator() {
        let section = TopicSection(
            topicId: 42,
            topicName: "SwiftUI",
            videos: [
                makeGridVideo(id: "a", title: "Old", channelName: "Alpha", publishedAt: "2 months ago", channelIconURL: "https://example.com/a.png"),
                makeGridVideo(id: "b", title: "New", channelName: "Alpha", publishedAt: "today", channelIconURL: "https://example.com/a.png"),
                makeGridVideo(id: "c", title: "Beta", channelName: "Beta", publishedAt: "10 days ago")
            ],
            totalCount: 3
        )

        let grouped = GridSectionLogic.groupByCreator(
            section: section,
            ascending: false,
            channelCounts: ["Alpha": 2, "Beta": 1],
            includeTopicMarker: true
        )

        #expect(grouped.count == 3)
        #expect(grouped[0].videos.isEmpty)
        #expect(grouped[1].creatorName == "Alpha")
        #expect(grouped[1].videos.map(\.id) == ["b", "a"])
        #expect(grouped[1].totalCount == 2)
        #expect(grouped[2].creatorName == "Beta")
    }
}
