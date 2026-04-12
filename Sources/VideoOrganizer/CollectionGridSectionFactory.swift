import Foundation
import TaggingKit

@MainActor
enum CollectionGridSectionFactory {
    static func buildSections(
        store: OrganizerStore,
        displaySettings: DisplaySettings
    ) -> GridSectionBuilder.Result {
        GridSectionBuilder.build(
            context: GridSectionBuilder.Context(
                topics: store.topics,
                parsedQuery: store.parsedQuery,
                selectedSubtopicId: store.selectedSubtopicId,
                selectedTopicId: store.selectedTopicId,
                selectedChannelId: store.selectedChannelId,
                selectedPlaylistId: store.selectedPlaylistId,
                sortOrder: displaySettings.sortOrder,
                sortAscending: displaySettings.sortAscending,
                channelCounts: store.channelCounts,
                pageDisplayMode: store.pageDisplayMode,
                watchPresentationMode: store.watchPresentationMode,
                displayModeForTopic: { store.displayMode(for: $0) },
                videosForTopic: { topicId, displayMode in
                    videosForTopic(topicId, displayMode: displayMode, store: store)
                },
                videosForSubtopic: { subtopicId in
                    mapVideos(store.videosForTopic(subtopicId), store: store)
                },
                allWatchVideos: {
                    store.candidateVideosForAllTopics().map { candidate in
                        VideoGridItemModel(
                            id: candidate.videoId,
                            topicId: candidate.topicId,
                            title: candidate.title,
                            channelName: candidate.channelName,
                            topicName: store.topics.first(where: { $0.id == candidate.topicId })?.name,
                            thumbnailUrl: candidate.thumbnailUrl,
                            viewCount: candidate.viewCount,
                            publishedAt: candidate.publishedAt,
                            duration: candidate.duration,
                            channelIconUrl: candidate.channelIconUrl.flatMap(URL.init(string:)),
                            channelId: candidate.channelId,
                            candidateScore: candidate.score,
                            stateTag: store.badgeTagForVideo(
                                candidate.videoId,
                                candidateState: candidate.state,
                                topicId: candidate.topicId,
                                channelId: candidate.channelId
                            ),
                            isPlaceholder: false,
                            placeholderMessage: candidate.secondaryText,
                            channelIconData: candidate.channelId.flatMap { store.knownChannelsById[$0]?.iconData }
                        )
                    }
                },
                videoIsInSelectedPlaylist: { store.videoIsInSelectedPlaylist($0) },
                handleForChannelId: { channelId in
                    store.topicChannels.values
                        .lazy
                        .flatMap { $0 }
                        .first(where: { $0.channelId == channelId })?.handle
                }
            )
        )
    }

    private static func mapVideos(
        _ viewModels: [VideoViewModel],
        store: OrganizerStore
    ) -> [VideoGridItemModel] {
        viewModels.map { video in
            VideoGridItemModel(
                id: video.videoId,
                topicId: video.topicId,
                title: video.title,
                channelName: video.channelName,
                topicName: store.topicNameForVideo(video.videoId),
                thumbnailUrl: video.thumbnailUrl,
                viewCount: video.viewCount,
                publishedAt: video.publishedAt,
                duration: video.duration,
                channelIconUrl: video.channelIconUrl.flatMap(URL.init(string:)),
                channelId: video.channelId,
                candidateScore: nil,
                stateTag: store.badgeTagForVideo(video.videoId),
                isPlaceholder: false,
                placeholderMessage: nil,
                channelIconData: video.channelId.flatMap { store.knownChannelsById[$0]?.iconData }
            )
        }
    }

    private static func videosForTopic(
        _ topicId: Int64,
        displayMode: TopicDisplayMode,
        store: OrganizerStore
    ) -> [VideoGridItemModel] {
        switch displayMode {
        case .saved:
            return mapVideos(store.videosForTopic(topicId), store: store)
        case .watchCandidates:
            return store.candidateVideosForTopic(topicId).map { candidate in
                VideoGridItemModel(
                    id: candidate.videoId,
                    topicId: candidate.topicId,
                    title: candidate.title,
                    channelName: candidate.channelName,
                    topicName: store.topics.first(where: { $0.id == topicId })?.name,
                    thumbnailUrl: candidate.thumbnailUrl,
                    viewCount: candidate.viewCount,
                    publishedAt: candidate.publishedAt,
                    duration: candidate.duration,
                    channelIconUrl: candidate.channelIconUrl.flatMap(URL.init(string:)),
                    channelId: candidate.channelId,
                    candidateScore: candidate.score,
                    stateTag: store.badgeTagForVideo(
                        candidate.videoId,
                        candidateState: candidate.state,
                        topicId: candidate.topicId,
                        channelId: candidate.channelId
                    ),
                    isPlaceholder: candidate.isPlaceholder,
                    placeholderMessage: candidate.secondaryText,
                    channelIconData: candidate.channelId.flatMap { store.knownChannelsById[$0]?.iconData }
                )
            }
        }
    }
}
