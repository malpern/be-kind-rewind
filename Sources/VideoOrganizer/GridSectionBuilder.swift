import Foundation

struct GridSectionBuilder {
    struct Context {
        let topics: [TopicViewModel]
        let parsedQuery: SearchQuery
        let selectedSubtopicId: Int64?
        let selectedTopicId: Int64?
        let selectedChannelId: String?
        let selectedPlaylistId: String?
        let sortOrder: SortOrder?
        let sortAscending: Bool
        let channelCounts: [String: Int]
        let pageDisplayMode: TopicDisplayMode
        let watchPresentationMode: WatchPresentationMode
        let displayModeForTopic: (Int64) -> TopicDisplayMode
        let videosForTopic: (Int64, TopicDisplayMode) -> [VideoGridItemModel]
        let videosForSubtopic: (Int64) -> [VideoGridItemModel]
        let allWatchVideos: () -> [VideoGridItemModel]
        let videoIsInSelectedPlaylist: (String) -> Bool
    }

    struct Result {
        let sections: [TopicSection]
        let searchResultCount: Int
    }

    static func build(context: Context) -> Result {
        var baseSections: [TopicSection] = []

        if context.pageDisplayMode == .watchCandidates,
           context.watchPresentationMode == .allTogether {
            // "Show All" deliberately ignores the sidebar topic selection — the whole
            // point of this mode is to merge candidates from every topic into one
            // ranked pool. Previously this code re-filtered by selectedTopicId, which
            // made Show All collapse to "show only this one topic" whenever the user
            // had any topic selected in the sidebar.
            let allWatchVideos = context.allWatchVideos()
            if !allWatchVideos.isEmpty {
                baseSections = [
                    TopicSection(
                        topicId: -1,
                        topicName: "Watch",
                        videos: allWatchVideos,
                        displayMode: .watchCandidates
                    )
                ]
            }
        } else {
            for topic in context.topics {
                let displayMode = context.displayModeForTopic(topic.id)
                if topic.subtopics.isEmpty {
                    let videos = context.videosForTopic(topic.id, displayMode)
                    if !videos.isEmpty {
                        baseSections.append(
                            TopicSection(topicId: topic.id, topicName: topic.name, videos: videos, displayMode: displayMode)
                        )
                    }
                    continue
                }

                var allVideos: [VideoGridItemModel] = []
                var subtopicMap: [String: Int64] = [:]
                if displayMode == .saved {
                    for sub in topic.subtopics {
                        let videos = context.videosForSubtopic(sub.id)
                        for video in videos {
                            subtopicMap[video.id] = sub.id
                        }
                        allVideos.append(contentsOf: videos)
                    }
                    allVideos.append(contentsOf: context.videosForTopic(topic.id, .saved))
                } else {
                    allVideos = context.videosForTopic(topic.id, displayMode)
                }

                if !allVideos.isEmpty {
                    baseSections.append(
                        TopicSection(
                            topicId: topic.id,
                            topicName: topic.name,
                            videos: allVideos,
                            videoSubtopicMap: subtopicMap,
                            displayMode: displayMode
                        )
                    )
                }
            }
        }

        let filteredResult = filterBySearch(query: context.parsedQuery, sections: baseSections)
        var result = filteredResult.sections

        if let subtopicId = context.selectedSubtopicId {
            result = result.compactMap { section in
                guard section.displayMode == .saved else { return section }
                let filtered = section.videos.filter { section.videoSubtopicMap[$0.id] == subtopicId }
                guard !filtered.isEmpty else { return nil }
                return TopicSection(
                    topicId: section.topicId,
                    topicName: section.topicName,
                    videos: filtered,
                    totalCount: section.videos.count,
                    videoSubtopicMap: section.videoSubtopicMap,
                    displayMode: section.displayMode
                )
            }
        }

        if let channelId = context.selectedChannelId {
            result = result.compactMap { section in
                let filtered = section.videos.filter { $0.channelId == channelId }
                guard !filtered.isEmpty else { return nil }
                return TopicSection(
                    topicId: section.topicId,
                    topicName: section.topicName,
                    videos: filtered,
                    totalCount: section.videos.count,
                    videoSubtopicMap: section.videoSubtopicMap,
                    displayMode: section.displayMode
                )
            }
        }

        if context.selectedPlaylistId != nil {
            result = result.compactMap { section in
                guard section.displayMode == .saved else { return section }
                let filtered = section.videos.filter { context.videoIsInSelectedPlaylist($0.id) }
                guard !filtered.isEmpty else { return nil }
                return TopicSection(
                    topicId: section.topicId,
                    topicName: section.topicName,
                    videos: filtered,
                    totalCount: section.videos.count,
                    videoSubtopicMap: section.videoSubtopicMap,
                    displayMode: section.displayMode
                )
            }
        }

        if let sortOrder = context.sortOrder {
            if sortOrder == .creator {
                result = result.flatMap { section in
                    GridSectionLogic.groupByCreator(
                        section: section,
                        ascending: context.sortAscending,
                        channelCounts: context.channelCounts,
                        includeTopicMarker: context.watchPresentationMode == .allTogether ? false : true
                    )
                }
            } else {
                result = result.map { section in
                    return TopicSection(
                        topicId: section.topicId,
                        topicName: section.topicName,
                        videos: GridSectionLogic.sortVideos(section.videos, by: sortOrder, ascending: context.sortAscending),
                        totalCount: section.totalCount,
                        videoSubtopicMap: section.videoSubtopicMap,
                        displayMode: section.displayMode
                    )
                }
            }
        } else if context.pageDisplayMode == .watchCandidates,
                  context.watchPresentationMode == .allTogether {
            result = result.map { section in
                TopicSection(
                    topicId: section.topicId,
                    topicName: section.topicName,
                    videos: section.videos.sorted { lhs, rhs in
                        let lhsScore = lhs.candidateScore ?? 0
                        let rhsScore = rhs.candidateScore ?? 0
                        if lhsScore == rhsScore {
                            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                        }
                        return lhsScore > rhsScore
                    },
                    totalCount: section.totalCount,
                    videoSubtopicMap: section.videoSubtopicMap,
                    displayMode: section.displayMode
                )
            }
        }

        return Result(sections: result, searchResultCount: filteredResult.searchResultCount)
    }

    private static func filterBySearch(query: SearchQuery, sections: [TopicSection]) -> Result {
        guard !query.isEmpty else {
            return Result(sections: sections, searchResultCount: 0)
        }

        var filteredSections: [TopicSection] = []
        for section in sections {
            if query.matches(fields: [section.topicName]) {
                filteredSections.append(
                    TopicSection(
                        topicId: section.topicId,
                        topicName: section.topicName,
                        videos: section.videos,
                        totalCount: section.videos.count,
                        videoSubtopicMap: section.videoSubtopicMap,
                        displayMode: section.displayMode
                    )
                )
                continue
            }

            let matchingVideos = section.videos.filter { video in
                query.matches(fields: [video.title, video.channelName ?? "", video.topicName ?? section.topicName])
            }
            if !matchingVideos.isEmpty {
                filteredSections.append(
                    TopicSection(
                        topicId: section.topicId,
                        topicName: section.topicName,
                        videos: matchingVideos,
                        totalCount: section.videos.count,
                        videoSubtopicMap: section.videoSubtopicMap,
                        displayMode: section.displayMode
                    )
                )
            }
        }

        let searchResultCount = filteredSections.reduce(0) { $0 + $1.videos.count }
        return Result(sections: filteredSections, searchResultCount: searchResultCount)
    }
}
