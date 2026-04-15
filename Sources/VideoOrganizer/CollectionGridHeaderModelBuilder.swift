import Foundation
import TaggingKit

@MainActor
struct CollectionGridHeaderModelBuilder {
    let store: OrganizerStore?
    let renderedSections: [TopicSection]
    let topicScrollProgress: (Int64) -> Double
    let sectionScrollProgress: (Int) -> Double

    func headerHeight(for section: TopicSection) -> CGFloat {
        if section.creatorName != nil {
            return 56
        }

        let channels = headerChannels(for: section)
        return channels.isEmpty ? 48 : 112
    }

    func headerModel(for section: TopicSection, at sectionIndex: Int?) -> CollectionSectionHeaderModel {
        let startedAt = ContinuousClock.now
        defer {
            let duration = startedAt.duration(to: .now)
            let millis = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
            if millis >= 50 {
                AppLogger.file.log("⏱ headerModel topic=\(section.topicId) name=\(section.topicName) mode=\(section.displayMode.rawValue) took \(Int(millis))ms", category: "perf")
            }
        }
        let scrollProgress: Double
        if section.creatorName != nil || isTopicMarkerInCreatorGrouping(section) {
            scrollProgress = topicScrollProgress(section.topicId)
        } else {
            scrollProgress = sectionIndex.map(sectionScrollProgress) ?? 0
        }

        if let creatorName = section.creatorName {
            let iconData = section.creatorChannelId.flatMap { store?.knownChannelsById[$0]?.iconData }
            return .creator(
                channelName: creatorName,
                channelIconUrl: section.channelIconUrl,
                channelIconData: iconData,
                channelUrl: section.creatorChannelUrl,
                count: section.videos.count,
                totalCount: section.totalCount,
                topicNames: section.topicNames,
                sectionId: section.id,
                scrollProgress: scrollProgress,
                highlightTerms: store?.parsedQuery.includeTerms ?? [],
                onInspect: { [weak store] in
                    _ = store?.navigateToCreator(
                        channelId: section.creatorChannelId,
                        channelName: creatorName,
                        preferredTopicId: section.topicId
                    )
                }
            )
        }

        let highlightTerms = store?.parsedQuery.includeTerms ?? []
        let channels = headerChannels(for: section)
        let selectedChannelId = store?.selectedChannelId
        let watchCandidatesForSection = section.displayMode == .watchCandidates
            ? (section.topicId == -1
                ? store?.recentCandidateVideosForAllTopics() ?? []
                : store?.recentStoredCandidateVideosForTopic(section.topicId) ?? [])
            : []

        let topicId = section.topicId
        let displayMode = section.displayMode
        let videoCount: (String) -> Int = { [weak store] channelId in
            guard let store else { return 0 }
            if displayMode == .watchCandidates {
                let channel = channels.first(where: { $0.channelId == channelId })
                return store.watchCandidateCountForChannel(
                    channel?.channelId ?? channelId,
                    channelName: channel?.name,
                    inCandidates: watchCandidatesForSection
                )
            }
            return store.videoCountForChannel(channelId, inTopic: topicId)
        }
        let hasRecent: (String) -> Bool = { [weak store] channelId in
            guard let store else { return false }
            if displayMode == .watchCandidates {
                let channel = channels.first(where: { $0.channelId == channelId })
                return store.latestWatchCandidateDateForChannel(
                    channel?.channelId ?? channelId,
                    channelName: channel?.name,
                    inCandidates: watchCandidatesForSection
                ) != nil
            }
            return store.channelHasRecentContent(channelId, inTopic: topicId)
        }
        let latestPublishedAt: (String) -> Date? = { [weak store] channelId in
            guard let store else { return nil }
            if displayMode == .watchCandidates {
                let channel = channels.first(where: { $0.channelId == channelId })
                return store.latestWatchCandidateDateForChannel(
                    channel?.channelId ?? channelId,
                    channelName: channel?.name,
                    inCandidates: watchCandidatesForSection
                )
            }
            return latestSavedPublishedDateForChannel(channelId, topicId: topicId, store: store)
        }
        let themeLabels: (String) -> [String] = { [weak store] channelId in
            guard let store else { return [] }
            let themes = (try? store.store.creatorThemes(channelId: channelId)) ?? []
            return themes
                .sorted { $0.videoIds.count > $1.videoIds.count }
                .map(\.label)
        }
        let subscriberCount: (String) -> String? = { channelId in
            channels.first(where: { $0.channelId == channelId })?.subscriberCount
        }
        let onSelect: (String) -> Void = { [weak store] channelId in
            guard let store else { return }
            if store.selectedChannelId == channelId {
                store.selectedChannelId = nil
                store.inspectedCreatorName = nil
                store.selectedVideoId = nil
                return
            }
            let channel = channels.first(where: { $0.channelId == channelId })
            if displayMode == .watchCandidates {
                _ = store.navigateToCreatorInWatch(
                    channelId: channel?.channelId ?? channelId,
                    channelName: channel?.name,
                    preferredTopicId: topicId
                )
            } else {
                _ = store.navigateToCreator(
                    channelId: channelId,
                    channelName: channel?.name,
                    preferredTopicId: topicId
                )
            }
        }
        let onOpenDetail: (String) -> Void = { [weak store] channelId in
            store?.openCreatorDetail(channelId: channelId)
        }

        return .topic(
            name: section.topicName,
            count: section.headerCountOverride ?? section.videos.count,
            totalCount: section.totalCount,
            topicId: section.topicId,
            scrollProgress: scrollProgress,
            highlightTerms: highlightTerms,
            displayMode: section.displayMode,
            channels: channels,
            selectedChannelId: selectedChannelId,
            videoCountForChannel: videoCount,
            hasRecentContent: hasRecent,
            latestPublishedAtForChannel: latestPublishedAt,
            themeLabelsForChannel: themeLabels,
            subscriberCountForChannel: subscriberCount,
            onSelectChannel: onSelect,
            onOpenCreatorDetail: onOpenDetail
        )
    }

    private func headerChannels(for section: TopicSection) -> [ChannelRecord] {
        guard let store else { return [] }
        if section.displayMode == .watchCandidates {
            return watchChannels(for: section, store: store)
        }
        return store.channelsForTopic(section.topicId)
    }

    private func watchChannels(for section: TopicSection, store: OrganizerStore) -> [ChannelRecord] {
        let sourceVideos: [CandidateVideoViewModel]
        if section.topicId == -1 {
            sourceVideos = store.watchPoolForAllTopics(applyingChannelFilter: false)
        } else {
            sourceVideos = store.watchPoolForTopic(section.topicId, applyingChannelFilter: false)
        }

        var bestByChannelId: [String: ChannelRecord] = [:]
        for video in sourceVideos where !video.isPlaceholder {
            let channelId = if let channelId = video.channelId, !channelId.isEmpty {
                channelId
            } else {
                "watch-\(video.channelName ?? "unknown")"
            }
            guard bestByChannelId[channelId] == nil else { continue }
            if let resolved = store.resolvedChannelRecord(
                channelId: video.channelId,
                fallbackName: video.channelName ?? "Unknown Creator",
                fallbackIconURL: video.channelIconUrl
            ) {
                bestByChannelId[channelId] = resolved
            }
        }

        return Array(bestByChannelId.values)
    }

    private func latestSavedPublishedDateForChannel(
        _ channelId: String,
        topicId: Int64,
        store: OrganizerStore
    ) -> Date? {
        store.videosForTopicIncludingSubtopics(topicId)
            .filter { $0.channelId == channelId }
            .compactMap { video in
                guard let publishedAt = video.publishedAt else { return nil }
                return parsedPublishedDate(from: publishedAt)
            }
            .max()
    }

    private func parsedPublishedDate(from publishedAt: String) -> Date? {
        if let iso = CreatorAnalytics.parseISO8601Date(publishedAt) {
            return iso
        }
        let ageDays = CreatorAnalytics.parseAge(publishedAt)
        guard ageDays != .max else { return nil }
        return Calendar.current.date(byAdding: .day, value: -ageDays, to: Date())
    }

    private func isTopicMarkerInCreatorGrouping(_ section: TopicSection) -> Bool {
        section.creatorName == nil && renderedSections.contains {
            $0.topicId == section.topicId && $0.creatorName != nil
        }
    }
}
