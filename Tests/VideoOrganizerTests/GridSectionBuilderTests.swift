import Foundation
import Testing
@testable import VideoOrganizer

@Suite("GridSectionBuilder")
struct GridSectionBuilderTests {
    @Test("build filters saved sections by search subtopic and playlist")
    func buildFiltersSections() {
        let topic = TopicViewModel(
            id: 1,
            name: "SwiftUI",
            videoCount: 3,
            subtopics: [
                TopicViewModel(id: 2, name: "Layout", videoCount: 1),
                TopicViewModel(id: 3, name: "Animation", videoCount: 1)
            ]
        )
        let context = GridSectionBuilder.Context(
            topics: [topic],
            parsedQuery: SearchQuery("alpha"),
            selectedSubtopicId: 2,
            selectedChannelId: nil,
            selectedPlaylistId: "PL-1",
            sortOrder: nil,
            sortAscending: false,
            channelCounts: [:],
            pageDisplayMode: .saved,
            watchPresentationMode: .byTopic,
            displayModeForTopic: { _ in .saved },
            videosForTopic: { _, _ in
                [Self.video(id: "topic-root", title: "Alpha Root", channel: "Alpha Channel", channelId: "chan-alpha")]
            },
            videosForSubtopic: { subtopicId in
                switch subtopicId {
                case 2:
                    return [Self.video(id: "sub-layout", title: "Alpha Layout", channel: "Alpha Channel", channelId: "chan-alpha")]
                case 3:
                    return [Self.video(id: "sub-animation", title: "Beta Animation", channel: "Beta Channel", channelId: "chan-beta")]
                default:
                    return []
                }
            },
            allWatchVideos: { [] },
            videoIsInSelectedPlaylist: { $0 == "sub-layout" }
        )

        let result = GridSectionBuilder.build(context: context)

        #expect(result.searchResultCount == 2)
        #expect(result.sections.count == 1)
        #expect(result.sections.first?.videos.map { $0.id } == ["sub-layout"])
        #expect(result.sections.first?.totalCount == 1)
    }

    @Test("build groups saved videos by creator and keeps topic marker")
    func buildGroupsByCreator() {
        let topic = TopicViewModel(id: 1, name: "SwiftUI", videoCount: 3)
        let context = GridSectionBuilder.Context(
            topics: [topic],
            parsedQuery: SearchQuery(""),
            selectedSubtopicId: nil,
            selectedChannelId: nil,
            selectedPlaylistId: nil,
            sortOrder: .creator,
            sortAscending: false,
            channelCounts: ["Alpha Channel": 2, "Beta Channel": 1],
            pageDisplayMode: .saved,
            watchPresentationMode: .byTopic,
            displayModeForTopic: { _ in .saved },
            videosForTopic: { _, _ in
                [
                    Self.video(id: "a-new", title: "Alpha New", channel: "Alpha Channel", publishedAt: "today", channelId: "chan-alpha"),
                    Self.video(id: "a-old", title: "Alpha Old", channel: "Alpha Channel", publishedAt: "10 days ago", channelId: "chan-alpha"),
                    Self.video(id: "b-one", title: "Beta One", channel: "Beta Channel", publishedAt: "2 days ago", channelId: "chan-beta")
                ]
            },
            videosForSubtopic: { _ in [] },
            allWatchVideos: { [] },
            videoIsInSelectedPlaylist: { _ in true }
        )

        let result = GridSectionBuilder.build(context: context)

        #expect(result.sections.count == 3)
        #expect(result.sections[0].videos.isEmpty)
        #expect(result.sections[0].headerCountOverride == 3)
        #expect(result.sections[1].creatorName == "Alpha Channel")
        #expect(result.sections[1].videos.map { $0.id } == ["a-new", "a-old"])
        #expect(result.sections[2].creatorName == "Beta Channel")
    }

    private static func video(
        id: String,
        title: String,
        channel: String,
        publishedAt: String? = nil,
        channelId: String
    ) -> VideoGridItemModel {
        VideoGridItemModel(
            id: id,
            title: title,
            channelName: channel,
            topicName: nil,
            thumbnailUrl: nil,
            viewCount: nil,
            publishedAt: publishedAt,
            duration: nil,
            channelIconUrl: nil,
            channelId: channelId,
            candidateScore: nil,
            stateTag: nil,
            isPlaceholder: false,
            placeholderMessage: nil
        )
    }
}
