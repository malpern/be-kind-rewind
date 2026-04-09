import Foundation
import TaggingKit

extension OrganizerStore {
    private func assignedWatchPools(applyingChannelFilter: Bool = true) -> [Int64: [CandidateVideoViewModel]] {
        let assignment = watchPoolByTopic
        guard applyingChannelFilter, let selectedChannelId else {
            return assignment
        }

        return assignment.mapValues { candidates in
            candidates.filter { $0.channelId == selectedChannelId }
        }
    }

    func storedCandidateVideosForTopic(_ topicId: Int64) -> [CandidateVideoViewModel] {
        storedCandidateVideosByTopic[topicId] ?? []
    }

    func watchPoolForTopic(_ topicId: Int64, applyingChannelFilter: Bool = true) -> [CandidateVideoViewModel] {
        assignedWatchPools(applyingChannelFilter: applyingChannelFilter)[topicId] ?? []
    }

    func watchPoolForAllTopics(applyingChannelFilter: Bool = true) -> [CandidateVideoViewModel] {
        let reranked = rankedWatchPool

        guard applyingChannelFilter, let selectedChannelId else {
            return reranked
        }

        return reranked.filter { candidate in
            candidate.channelId == selectedChannelId
        }
    }

    func activatePageDisplayMode(_ mode: TopicDisplayMode) async {
        setPageDisplayMode(mode)
        guard mode == .watchCandidates else {
            return
        }
        rebuildWatchPools()
        ensureCandidatesForWatchPage()
    }

    func candidateVideosForTopic(_ topicId: Int64) -> [CandidateVideoViewModel] {
        let storedCandidates = storedCandidateVideosForTopic(topicId)
        let visibleCandidates = watchPoolForTopic(topicId)
        if !visibleCandidates.isEmpty {
            return visibleCandidates
        }

        if candidateLoadingTopics.contains(topicId) {
            return [.placeholder(
                topicId: topicId,
                title: "Refreshing Watch",
                message: "Looking for recent videos for this topic."
            )]
        }

        if let error = candidateErrors[topicId] {
            return [.placeholder(topicId: topicId, title: "Could not load candidates", message: error)]
        }

        if storedCandidates.isEmpty {
            return [.placeholder(
                topicId: topicId,
                title: "No candidates yet",
                message: "No unseen candidates were found from this topic’s creators or adjacent saved-library channels.\(watchHistoryHintSuffix)"
            )]
        }

        return [.placeholder(
            topicId: topicId,
            title: "No recent videos",
            message: "No recent unseen videos were found for this topic in the current watch window."
        )]
    }

    private var watchHistoryHintSuffix: String {
        guard seenHistoryCount == 0 else { return "" }
        return " Watch history import is optional, but adding it in Settings helps filter out videos you've already watched."
    }

    func candidateVideosForAllTopics() -> [CandidateVideoViewModel] {
        watchPoolForAllTopics()
    }

    func candidateProgress(for topicId: Int64) -> Double {
        candidateProgressByTopic[topicId] ?? 0
    }

    func candidateProgressTitle(for topicId: Int64) -> String {
        let completed = candidateCompletedChannelsByTopic[topicId] ?? 0
        let total = candidateTotalChannelsByTopic[topicId] ?? 0
        guard total > 0 else { return "Finding candidates for this topic" }
        return "Scanning discovery channels: \(completed) of \(total)"
    }

    func candidateProgressDetail(for topicId: Int64) -> String {
        let completed = candidateCompletedChannelsByTopic[topicId] ?? 0
        let total = candidateTotalChannelsByTopic[topicId] ?? 0
        let channelName = candidateCurrentChannelNameByTopic[topicId]

        guard total > 0 else {
            return "Preparing cached archives, adjacent creators, and candidate ranking."
        }

        if completed >= total {
            return "Finished checking \(total) discovery channel\(total == 1 ? "" : "s"). Ranking the freshest matches now."
        }

        if let channelName, !channelName.isEmpty {
            return "Checking \(channelName)'s archive, fetching only fresh uploads if needed, and ranking unseen videos."
        }

        return "Checking creator archives, fetching fresh uploads if needed, and ranking unseen videos."
    }

    var candidateProgressOverlay: CandidateProgressOverlayState? {
        guard pageDisplayMode == .watchCandidates,
              watchRefreshTotalTopics > 0 else {
            return nil
        }

        return CandidateProgressOverlayState(
            topicId: selectedTopicId ?? -1,
            topicName: watchRefreshCurrentTopicName ?? "All Topics",
            progress: watchRefreshTotalTopics > 0 ? Double(watchRefreshCompletedTopics) / Double(watchRefreshTotalTopics) : 0,
            title: watchRefreshCurrentTopicName == nil
                ? "Refreshing Watch"
                : "Updated \(watchRefreshCompletedTopics) of \(watchRefreshTotalTopics) topics",
            detail: ""
        )
    }

    func setCandidateState(topicId: Int64, videoId: String, state: CandidateState) {
        do {
            try store.setCandidateState(topicId: topicId, videoId: videoId, state: state)
            reloadStoredCandidateCache(for: topicId)
            rebuildWatchPools()
            AppLogger.discovery.info("Set candidate state for topic \(topicId, privacy: .public), video \(videoId, privacy: .public) to \(state.rawValue, privacy: .public)")
            candidateRefreshToken += 1
        } catch {
            AppLogger.discovery.error("Failed to set candidate state for topic \(topicId, privacy: .public), video \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func ensureCandidates(for topicId: Int64) async {
        guard !candidateLoadingTopics.contains(topicId) else { return }
        candidateLoadingTopics.insert(topicId)
        candidateProgressByTopic[topicId] = 0
        candidateCompletedChannelsByTopic[topicId] = 0
        candidateTotalChannelsByTopic[topicId] = 0
        candidateCurrentChannelNameByTopic[topicId] = nil
        candidateErrors[topicId] = nil
        if pageDisplayMode != .watchCandidates {
            candidateRefreshToken += 1
        }
        AppLogger.discovery.info("Starting candidate refresh for topic \(topicId, privacy: .public)")
        defer {
            candidateLoadingTopics.remove(topicId)
            candidateProgressByTopic[topicId] = nil
            candidateCompletedChannelsByTopic[topicId] = nil
            candidateTotalChannelsByTopic[topicId] = nil
            candidateCurrentChannelNameByTopic[topicId] = nil
            if pageDisplayMode != .watchCandidates {
                candidateRefreshToken += 1
            }
            AppLogger.discovery.info("Finished candidate refresh for topic \(topicId, privacy: .public)")
        }

        do {
            let channelPlans = CandidateDiscoveryCoordinator.candidateChannelPlans(for: topicId, store: self)
            guard !channelPlans.isEmpty else {
                try store.replaceCandidates(forTopic: topicId, candidates: [], sources: [])
                reloadStoredCandidateCache(for: topicId)
                rebuildWatchPools()
                return
            }

            let existingVideoIds = Set(videosForTopicIncludingSubtopics(topicId).map(\.videoId))
            var aggregate: [String: AggregatedCandidate] = [:]
            let totalChannels = max(channelPlans.count, 1)
            var completedChannels = 0
            candidateTotalChannelsByTopic[topicId] = channelPlans.count
            candidateCompletedChannelsByTopic[topicId] = 0
            candidateCurrentChannelNameByTopic[topicId] = channelPlans.first?.channel.name

            for plan in channelPlans {
                let archived = try await CandidateDiscoveryCoordinator.refreshChannelArchiveIfNeeded(
                    channel: plan.channel,
                    youtubeClient: youtubeClient,
                    store: self
                )

                candidateCurrentChannelNameByTopic[topicId] = plan.channel.name

                for video in archived {
                    let admission = CandidateDiscoveryCoordinator.watchTopicAdmission(
                        forTopic: topicId,
                        title: video.title,
                        sourceKind: plan.sourceKind,
                        sourceRef: plan.sourceRef,
                        store: self
                    )
                    guard admission.shouldAdmit else { continue }
                    CandidateDiscoveryCoordinator.accumulateCandidate(
                        video: video,
                        channel: plan.channel,
                        sourceKind: plan.sourceKind,
                        sourceRef: plan.sourceRef,
                        creatorAffinity: plan.creatorAffinity,
                        reasonHint: plan.reasonHint,
                        topicalEvidenceBonus: admission.scoreBonus,
                        existingVideoIds: existingVideoIds,
                        aggregate: &aggregate
                    )
                }

                completedChannels += 1
                candidateCompletedChannelsByTopic[topicId] = completedChannels
                candidateProgressByTopic[topicId] = Double(completedChannels) / Double(totalChannels)
            }

            if let youtubeClient {
                let searchPlans = CandidateDiscoveryCoordinator.searchPlans(for: topicId, store: self)
                for plan in searchPlans {
                    do {
                        let results = try await youtubeClient.searchVideos(
                            query: plan.query,
                            maxResults: 5,
                            publishedAfterDays: 30
                        )

                        for video in results {
                            if let channelId = video.channelId, !channelId.isEmpty, isExcludedCreator(channelId) {
                                continue
                            }
                            let admission = CandidateDiscoveryCoordinator.watchTopicAdmission(
                                forTopic: topicId,
                                title: video.title,
                                sourceKind: "search_query_recent",
                                sourceRef: plan.query,
                                store: self
                            )
                            guard admission.shouldAdmit else { continue }
                            let creatorAffinity: Int
                            do {
                                creatorAffinity = try store.videoCountForChannel(channelId: video.channelId ?? "", inTopic: topicId)
                            } catch {
                                AppLogger.discovery.error("Failed to get channel video count: \(error.localizedDescription, privacy: .public)")
                                creatorAffinity = 0
                            }
                            let resolvedIconUrl = video.channelId.flatMap { cid in
                                resolvedChannelRecord(channelId: cid, fallbackName: nil, fallbackIconURL: nil)?.iconUrl
                            }
                            CandidateDiscoveryCoordinator.accumulateCandidate(
                                video: video,
                                sourceKind: "search_query_recent",
                                sourceRef: plan.query,
                                creatorAffinity: creatorAffinity,
                                reasonHint: plan.query,
                                topicalEvidenceBonus: admission.scoreBonus,
                                existingVideoIds: existingVideoIds,
                                aggregate: &aggregate,
                                channelIconUrl: resolvedIconUrl
                            )
                        }
                    } catch {
                        AppLogger.discovery.error("Search discovery failed for topic \(topicId, privacy: .public), query \(plan.query, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            let ranked = aggregate.values
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    }
                    return lhs.score > rhs.score
                }
                .prefix(36)

            let candidates = ranked.map { value in
                TopicCandidate(
                    topicId: topicId,
                    videoId: value.videoId,
                    title: value.title,
                    channelId: value.channelId,
                    channelName: value.channelName,
                    videoUrl: "https://www.youtube.com/watch?v=\(value.videoId)",
                    viewCount: value.viewCount,
                    publishedAt: value.publishedAt,
                    duration: value.duration,
                    channelIconUrl: value.channelIconUrl,
                    score: value.score,
                    reason: value.reason
                )
            }

            let sources = ranked.flatMap { value in
                value.sources.map { source in
                    CandidateSourceRecord(
                        topicId: topicId,
                        videoId: value.videoId,
                        sourceKind: source.kind,
                        sourceRef: source.ref
                    )
                }
            }

            try store.replaceCandidates(forTopic: topicId, candidates: candidates, sources: sources)
            reloadStoredCandidateCache(for: topicId)
            rebuildWatchPools()

            // Fetch missing channel icons in background (free, no quota)
            await fetchMissingChannelIcons(from: candidates)
        } catch {
            candidateErrors[topicId] = CandidateDiscoveryCoordinator.friendlyCandidateErrorMessage(for: error)
            CandidateDiscoveryCoordinator.presentQuotaAlertIfNeeded(for: error, store: self)
            AppLogger.discovery.error("Candidate refresh failed for topic \(topicId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Downloads channel icons for candidate creators that have a URL but no cached icon data.
    /// Uses the YouTube CDN directly (no API quota cost).
    private func fetchMissingChannelIcons(from candidates: [TopicCandidate]) async {
        // Collect unique channels that have an icon URL
        var channelsToFetch: [(channelId: String, iconUrl: URL)] = []
        var seen = Set<String>()

        for candidate in candidates {
            guard let channelId = candidate.channelId, !channelId.isEmpty,
                  let iconUrlString = candidate.channelIconUrl,
                  let iconUrl = URL(string: iconUrlString),
                  !seen.contains(channelId) else { continue }
            seen.insert(channelId)

            // Check if we already have icon data for this channel
            if let existing = knownChannelsById[channelId], existing.iconData != nil {
                continue
            }
            // Also check the database directly for channels not in our cache
            if let dbChannel = try? store.channelById(channelId), dbChannel.iconData != nil {
                continue
            }

            channelsToFetch.append((channelId, iconUrl))
        }

        guard !channelsToFetch.isEmpty else { return }
        AppLogger.discovery.info("Fetching \(channelsToFetch.count, privacy: .public) missing channel icons")

        for (channelId, iconUrl) in channelsToFetch {
            do {
                let (data, response) = try await URLSession.shared.data(from: iconUrl)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { continue }

                // Ensure the channel record exists before updating icon
                if (try? store.channelById(channelId)) == nil {
                    let name = candidates.first(where: { $0.channelId == channelId })?.channelName ?? "Unknown"
                    try store.upsertChannel(ChannelRecord(
                        channelId: channelId,
                        name: name,
                        channelUrl: "https://www.youtube.com/channel/\(channelId)",
                        iconUrl: iconUrl.absoluteString
                    ))
                }
                try store.updateChannelIcon(channelId: channelId, iconData: data)
                // Invalidate cache so next access picks up the icon from DB
                knownChannelsById.removeValue(forKey: channelId)
            } catch {
                // Non-critical — skip and continue
            }
        }

        if !channelsToFetch.isEmpty {
            rebuildWatchPools()
        }
    }

    func ensureCandidatesForWatchPage() {
        guard watchRefreshTask == nil else { return }

        let topicsToRefresh = topics
        watchRefreshTotalTopics = topicsToRefresh.count
        watchRefreshCompletedTopics = 0
        watchRefreshCurrentTopicName = selectedTopicId.flatMap { topicId in
            topicsToRefresh.first(where: { $0.id == topicId })?.name
        } ?? topicsToRefresh.first?.name

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.watchRefreshTask = nil
                self.watchRefreshTotalTopics = 0
                self.watchRefreshCompletedTopics = 0
                self.watchRefreshCurrentTopicName = nil
            }

            var remainingTopicIds = Set(topicsToRefresh.map(\.id))

            while !remainingTopicIds.isEmpty {
                let orderedIds = self.prioritizedWatchRefreshTopicIDs(from: Array(remainingTopicIds))
                guard let nextTopicId = orderedIds.first,
                      let topic = topicsToRefresh.first(where: { $0.id == nextTopicId }) else {
                    break
                }
                remainingTopicIds.remove(nextTopicId)
                AppLogger.discovery.debug(
                    "Watch refresh prioritizing topic \(topic.name, privacy: .public); remaining topics: \(remainingTopicIds.count, privacy: .public)"
                )
                self.watchRefreshCurrentTopicName = topic.name

                if !CandidateDiscoveryCoordinator.shouldUseCachedCandidates(for: topic.id, store: self) {
                    await self.ensureCandidates(for: topic.id)
                } else {
                    self.rebuildWatchPools()
                }

                self.watchRefreshCompletedTopics += 1
                await Task.yield()
            }
        }

        watchRefreshTask = task
    }
}

@MainActor
enum CandidateDiscoveryCoordinator {
    static func recentEligibleWatchVideos(_ videos: [CandidateVideoViewModel], store: OrganizerStore) -> [CandidateVideoViewModel] {
        videos.filter { video in
            !video.isPlaceholder && store.isRecentWatchPublishedAt(video.publishedAt)
        }
    }

    static func deduplicateWatchVideos(_ videos: [CandidateVideoViewModel]) -> [CandidateVideoViewModel] {
        var bestByVideoId: [String: CandidateVideoViewModel] = [:]

        for video in videos {
            guard let existing = bestByVideoId[video.videoId] else {
                bestByVideoId[video.videoId] = video
                continue
            }

            if prefers(video, over: existing) {
                bestByVideoId[video.videoId] = video
            }
        }

        return Array(bestByVideoId.values)
    }

    static func assignWatchVideosToTopics(_ perTopic: [Int64: [CandidateVideoViewModel]]) -> [Int64: [CandidateVideoViewModel]] {
        var bestByVideoId: [String: CandidateVideoViewModel] = [:]

        for (_, videos) in perTopic {
            for video in videos {
                guard let existing = bestByVideoId[video.videoId] else {
                    bestByVideoId[video.videoId] = video
                    continue
                }

                if prefers(video, over: existing) {
                    bestByVideoId[video.videoId] = video
                }
            }
        }

        var assigned: [Int64: [CandidateVideoViewModel]] = [:]
        for topicId in perTopic.keys {
            assigned[topicId] = []
        }

        for video in bestByVideoId.values {
            assigned[video.topicId, default: []].append(video)
        }

        for (topicId, videos) in assigned {
            assigned[topicId] = videos.sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    let lhsDate = CreatorAnalytics.parseISO8601Date(lhs.publishedAt ?? "")
                    let rhsDate = CreatorAnalytics.parseISO8601Date(rhs.publishedAt ?? "")
                    switch (lhsDate, rhsDate) {
                    case let (l?, r?) where l != r:
                        return l > r
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    default:
                        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    }
                }
                return lhs.score > rhs.score
            }
        }

        return assigned
    }

    static func rerankWatchVideos(_ videos: [CandidateVideoViewModel], store: OrganizerStore) -> [CandidateVideoViewModel] {
        let prelim = videos.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                let lhsDate = CreatorAnalytics.parseISO8601Date(lhs.publishedAt ?? "")
                let rhsDate = CreatorAnalytics.parseISO8601Date(rhs.publishedAt ?? "")
                switch (lhsDate, rhsDate) {
                case let (l?, r?) where l != r:
                    return l > r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.score > rhs.score
        }

        var creatorCounts: [String: Int] = [:]
        var scored: [(CandidateVideoViewModel, Double)] = []

        for video in prelim {
            let creatorKey = (video.channelId?.isEmpty == false ? video.channelId : video.channelName) ?? "unknown"
            let seenPenalty = appSeenPenalty(for: video, store: store)
            let repeatPenalty = creatorRepeatPenalty(for: video, currentCount: creatorCounts[creatorKey] ?? 0)
            let adjusted = video.score - seenPenalty - repeatPenalty
            scored.append((video, adjusted))
            creatorCounts[creatorKey, default: 0] += 1
        }

        return scored.sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                let lhsDate = CreatorAnalytics.parseISO8601Date(lhs.0.publishedAt ?? "")
                let rhsDate = CreatorAnalytics.parseISO8601Date(rhs.0.publishedAt ?? "")
                switch (lhsDate, rhsDate) {
                case let (l?, r?) where l != r:
                    return l > r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
                }
            }
            return lhs.1 > rhs.1
        }.map(\.0)
    }

    fileprivate static func candidateChannelPlans(for topicId: Int64, store: OrganizerStore) -> [CandidateChannelPlan] {
        let coreChannels = Array(
            store.channelsForTopic(topicId)
                .filter { !store.isExcludedCreator($0.channelId) }
                .prefix(candidateCreatorScanLimit(for: topicId, store: store))
        )
        var plans = coreChannels.map {
            CandidateChannelPlan(
                channel: $0,
                sourceKind: "channel_archive_recent",
                sourceRef: $0.channelId,
                creatorAffinity: store.videoCountForChannel($0.channelId, inTopic: topicId),
                reasonHint: nil
            )
        }

        let exploratory = exploratoryChannelsForTopic(
            topicId,
            excluding: Set(coreChannels.map(\.channelId)),
            limit: candidateExploratoryScanLimit(for: topicId, store: store),
            store: store
        )
        plans.append(contentsOf: exploratory.map {
            CandidateChannelPlan(
                channel: $0.channel,
                sourceKind: "playlist_adjacent_recent",
                sourceRef: $0.sourceRef,
                creatorAffinity: $0.affinity,
                reasonHint: $0.reasonHint
            )
        })
        return plans
    }

    fileprivate static func searchPlans(for topicId: Int64, store: OrganizerStore) -> [CandidateSearchPlan] {
        guard let topic = store.topics.first(where: { $0.id == topicId }) else { return [] }
        return generatedSearchQueries(for: topic).map(CandidateSearchPlan.init(query:))
    }

    private static func appSeenPenalty(for video: CandidateVideoViewModel, store: OrganizerStore) -> Double {
        guard let summary = store.seenSummary(for: video.videoId) else { return 0 }
        guard summary.latestSource == .app else { return 0 }
        let countPenalty = Double(min(summary.eventCount, 3)) * 18
        return countPenalty
    }

    private static func creatorRepeatPenalty(for video: CandidateVideoViewModel, currentCount: Int) -> Double {
        guard currentCount > 0 else { return 0 }
        let ageDays = ageDays(for: video.publishedAt)
        let ageMultiplier: Double
        switch ageDays {
        case ...14:
            ageMultiplier = 0.35
        case ...45:
            ageMultiplier = 0.75
        case ...120:
            ageMultiplier = 1.2
        default:
            ageMultiplier = 1.8
        }

        return Double(currentCount) * 16 * ageMultiplier
    }

    private static func ageDays(for publishedAt: String?) -> Int {
        guard let publishedAt, !publishedAt.isEmpty else { return .max }
        if let date = CreatorAnalytics.parseISO8601Date(publishedAt) {
            let days = Int(Date().timeIntervalSince(date) / 86_400)
            return max(days, 0)
        }
        return CreatorAnalytics.parseAge(publishedAt)
    }

    private static func prefers(_ lhs: CandidateVideoViewModel, over rhs: CandidateVideoViewModel) -> Bool {
        if lhs.assignmentStrength != rhs.assignmentStrength {
            return lhs.assignmentStrength > rhs.assignmentStrength
        }

        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }

        let lhsDate = CreatorAnalytics.parseISO8601Date(lhs.publishedAt ?? "")
        let rhsDate = CreatorAnalytics.parseISO8601Date(rhs.publishedAt ?? "")
        switch (lhsDate, rhsDate) {
        case let (l?, r?) where l != r:
            return l > r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    static func refreshChannelArchiveIfNeeded(channel: ChannelRecord, youtubeClient: YouTubeClient?, store: OrganizerStore) async throws -> [ArchivedChannelVideo] {
        let existingArchive = try store.store.archivedVideosForChannels([channel.channelId], perChannelLimit: 24)
        let knownVideoIDs = try store.store.archivedVideoIDsForChannel(channel.channelId)
        let lastScannedAt = try store.store.channelDiscoveryLastScannedAt(channelId: channel.channelId)
        guard shouldRefreshArchive(lastScannedAt: lastScannedAt) else {
            return existingArchive
        }

        do {
            guard let youtubeClient else {
                throw DiscoveryFallbackError.executionFailed("YouTube API key unavailable; using public discovery fallback.")
            }

            let incremental = try await youtubeClient.fetchIncrementalChannelUploads(
                channelId: channel.channelId,
                knownVideoIDs: knownVideoIDs,
                maxNewResults: 24,
                maxPages: 4
            )
            let scannedAt = ISO8601DateFormatter().string(from: Date())
            let archived = incremental.videos.map { video in
                ArchivedChannelVideo(
                    channelId: channel.channelId,
                    videoId: video.videoId,
                    title: video.title,
                    channelName: video.channelTitle ?? channel.name,
                    publishedAt: video.publishedAt,
                    duration: video.duration,
                    viewCount: video.viewCount,
                    channelIconUrl: channel.iconUrl,
                    fetchedAt: scannedAt
                )
            }
            try store.store.upsertChannelDiscoveryArchive(channelId: channel.channelId, videos: archived, scannedAt: scannedAt)
            return try store.store.archivedVideosForChannels([channel.channelId], perChannelLimit: 24)
        } catch {
            let recent = try await DiscoveryFallbackService(environment: store.runtimeEnvironment)
                .fetchRecentChannelUploads(channelId: channel.channelId, maxResults: 16)
                .filter { !knownVideoIDs.contains($0.videoId) }
            let scannedAt = ISO8601DateFormatter().string(from: Date())
            let archived = recent.map { video in
                ArchivedChannelVideo(
                    channelId: channel.channelId,
                    videoId: video.videoId,
                    title: video.title,
                    channelName: video.channelTitle ?? channel.name,
                    publishedAt: video.publishedAt,
                    duration: video.duration,
                    viewCount: video.viewCount,
                    channelIconUrl: channel.iconUrl,
                    fetchedAt: scannedAt
                )
            }
            try store.store.upsertChannelDiscoveryArchive(channelId: channel.channelId, videos: archived, scannedAt: scannedAt)
            return try store.store.archivedVideosForChannels([channel.channelId], perChannelLimit: 24)
        }
    }

    fileprivate static func accumulateCandidate(
        video: ArchivedChannelVideo,
        channel: ChannelRecord,
        sourceKind: String,
        sourceRef: String,
        creatorAffinity: Int,
        reasonHint: String?,
        topicalEvidenceBonus: Int,
        existingVideoIds: Set<String>,
        aggregate: inout [String: AggregatedCandidate]
    ) {
        accumulateCandidate(
            videoId: video.videoId,
            title: video.title,
            channelId: channel.channelId,
            channelName: video.channelName ?? channel.name,
            viewCount: video.viewCount,
            publishedAt: video.publishedAt,
            duration: video.duration,
            channelIconUrl: video.channelIconUrl ?? channel.iconUrl,
            sourceKind: sourceKind,
            sourceRef: sourceRef,
            creatorAffinity: creatorAffinity,
            reasonHint: reasonHint,
            topicalEvidenceBonus: topicalEvidenceBonus,
            existingVideoIds: existingVideoIds,
            aggregate: &aggregate
        )
    }

    fileprivate static func accumulateCandidate(
        video: DiscoveredVideo,
        sourceKind: String,
        sourceRef: String,
        creatorAffinity: Int,
        reasonHint: String?,
        topicalEvidenceBonus: Int,
        existingVideoIds: Set<String>,
        aggregate: inout [String: AggregatedCandidate],
        channelIconUrl: String? = nil
    ) {
        accumulateCandidate(
            videoId: video.videoId,
            title: video.title,
            channelId: video.channelId,
            channelName: video.channelTitle,
            viewCount: video.viewCount,
            publishedAt: video.publishedAt,
            duration: video.duration,
            channelIconUrl: channelIconUrl,
            sourceKind: sourceKind,
            sourceRef: sourceRef,
            creatorAffinity: creatorAffinity,
            reasonHint: reasonHint,
            topicalEvidenceBonus: topicalEvidenceBonus,
            existingVideoIds: existingVideoIds,
            aggregate: &aggregate
        )
    }

    private static func accumulateCandidate(
        videoId: String,
        title: String,
        channelId: String?,
        channelName: String?,
        viewCount: String?,
        publishedAt: String?,
        duration: String?,
        channelIconUrl: String?,
        sourceKind: String,
        sourceRef: String,
        creatorAffinity: Int,
        reasonHint: String?,
        topicalEvidenceBonus: Int,
        existingVideoIds: Set<String>,
        aggregate: inout [String: AggregatedCandidate]
    ) {
        guard !existingVideoIds.contains(videoId) else { return }

        let publishedDays = CreatorAnalytics.parseAge(publishedAt ?? "")
        let recencyBonus: Int
        switch publishedDays {
        case ...7: recencyBonus = 30
        case ...30: recencyBonus = 24
        case ...90: recencyBonus = 16
        case ...180: recencyBonus = 8
        default: recencyBonus = 2
        }

        let creatorBonus = min(creatorAffinity, 16)
        let qualityBonus = min(CreatorAnalytics.parseViewCount(viewCount ?? "") / 75_000, 6)

        let sourceScore: (freshness: Int, creatorWeight: Int, bonus: Int)
        let reason: String
        switch sourceKind {
        case "channel_archive_recent":
            sourceScore = (10, 3, 0)
            reason = "Fresh upload from a creator already in this topic"
        case "playlist_adjacent_recent":
            sourceScore = (6, 2, 8)
            if let reasonHint, !reasonHint.isEmpty {
                reason = "Fresh upload from a creator adjacent to this topic via \(reasonHint)"
            } else {
                reason = "Fresh upload from a creator adjacent to this topic in your saved library"
            }
        case "search_query_recent":
            sourceScore = (8, 1, 12)
            if let reasonHint, !reasonHint.isEmpty {
                reason = "Recent search match for this topic via \(reasonHint)"
            } else {
                reason = "Recent search match for this topic"
            }
        default:
            sourceScore = (4, 2, 0)
            reason = "Recent candidate from a related creator"
        }

        let score = Double(sourceScore.freshness + recencyBonus * 4 + creatorBonus * sourceScore.creatorWeight + qualityBonus + sourceScore.bonus + topicalEvidenceBonus)

        if var existing = aggregate[videoId] {
            existing.score += score + 3
            let nowHasCoreSource = existing.sources.contains(where: { $0.kind == "channel_archive_recent" }) || sourceKind == "channel_archive_recent"
            let nowHasAdjacentSource = existing.sources.contains(where: { $0.kind == "playlist_adjacent_recent" }) || sourceKind == "playlist_adjacent_recent"
            let nowHasSearchSource = existing.sources.contains(where: { $0.kind == "search_query_recent" }) || sourceKind == "search_query_recent"
            if nowHasCoreSource && nowHasAdjacentSource {
                existing.reason = "Fresh upload connected to this topic and your saved playlists"
            } else if nowHasCoreSource && nowHasSearchSource {
                existing.reason = "Fresh upload from a topic creator that also matched a topic search"
            } else if sourceKind == "playlist_adjacent_recent" {
                existing.reason = reason
            } else if sourceKind == "search_query_recent" {
                existing.reason = reason
            } else if sourceKind == "channel_archive_recent" {
                existing.reason = "Fresh upload from a creator already in this topic"
            }
            existing.sources.insert(CandidateSource(kind: sourceKind, ref: sourceRef))
            aggregate[videoId] = existing
            return
        }

        aggregate[videoId] = AggregatedCandidate(
            videoId: videoId,
            title: title,
            channelId: channelId,
            channelName: channelName,
            viewCount: viewCount,
            publishedAt: publishedAt,
            duration: duration,
            channelIconUrl: channelIconUrl,
            score: score,
            reason: reason,
            sources: [CandidateSource(kind: sourceKind, ref: sourceRef)]
        )
    }

    static func friendlyCandidateErrorMessage(for error: Error) -> String {
        if let youtubeError = error as? YouTubeError, youtubeError.isQuotaExceeded {
            return "YouTube API quota is exhausted for today. Existing saved videos still work, and candidate discovery will work again after quota resets at midnight Pacific."
        }
        return error.localizedDescription
    }

    static func presentQuotaAlertIfNeeded(for error: Error, store: OrganizerStore) {
        guard let youtubeError = error as? YouTubeError, youtubeError.isQuotaExceeded else { return }
        store.alert = AppAlertState(
            title: "YouTube Quota Exhausted",
            message: "The app has used today’s YouTube Data API quota for discovery. Candidate generation is paused until quota resets at midnight Pacific. Saved videos, playlists, and existing cached candidates are still available."
        )
    }

    static func shouldUseCachedCandidates(for topicId: Int64, store: OrganizerStore) -> Bool {
        guard let latest = try? store.store.latestCandidateDiscoveredAt(topicId: topicId),
              let latestDate = ISO8601DateFormatter().date(from: latest) else {
            return false
        }
        return Date().timeIntervalSince(latestDate) < (6 * 60 * 60)
    }

    private static func candidateCreatorScanLimit(for topicId: Int64, store: OrganizerStore) -> Int {
        switch store.channelsForTopic(topicId).count {
        case 0...6: return 6
        case 7...12: return 10
        case 13...24: return 12
        default: return 16
        }
    }

    private static func candidateExploratoryScanLimit(for topicId: Int64, store: OrganizerStore) -> Int {
        switch store.channelsForTopic(topicId).count {
        case 0...6: return 2
        case 7...12: return 3
        case 13...24: return 4
        default: return 6
        }
    }

    private static func exploratoryChannelsForTopic(_ topicId: Int64, excluding excludedChannelIds: Set<String>, limit: Int, store: OrganizerStore) -> [ExploratoryChannelCandidate] {
        guard limit > 0 else { return [] }

        let topicVideos = store.videosForTopicIncludingSubtopics(topicId)
        let topicVideoIDs = Set(topicVideos.map(\.videoId))
        guard !topicVideos.isEmpty else { return [] }

        var playlistWeights: [String: Double] = [:]
        var playlistTitles: [String: String] = [:]
        for video in topicVideos {
            for playlist in store.playlistsByVideoId[video.videoId] ?? [] {
                guard isUsefulDiscoveryPlaylist(playlist) else { continue }
                let videoCount = max(playlist.videoCount ?? 0, 1)
                let weight = 1.0 / max(log10(Double(max(videoCount, 10))), 1.0)
                playlistWeights[playlist.playlistId, default: 0] += weight
                playlistTitles[playlist.playlistId] = playlist.title
            }
        }

        guard !playlistWeights.isEmpty else { return [] }

        var overlapByChannel: [String: (score: Double, bestPlaylistId: String, sampleVideo: VideoViewModel, playlistIds: Set<String>)] = [:]
        for (videoId, playlists) in store.playlistsByVideoId {
            guard !topicVideoIDs.contains(videoId),
                  let video = store.videoMap[videoId],
                  let channelId = video.channelId,
                  !channelId.isEmpty,
                  !excludedChannelIds.contains(channelId),
                  !store.isExcludedCreator(channelId) else {
                continue
            }

            var overlapScore = 0.0
            var bestPlaylist: (id: String, score: Double)?
            for playlist in playlists {
                guard let weight = playlistWeights[playlist.playlistId] else { continue }
                overlapScore += weight
                if bestPlaylist == nil || weight > bestPlaylist!.score {
                    bestPlaylist = (playlist.playlistId, weight)
                }
            }

            guard overlapScore > 0, let bestPlaylist else { continue }

            if let current = overlapByChannel[channelId] {
                var playlistIds = current.playlistIds
                playlists.forEach { playlist in
                    if playlistWeights[playlist.playlistId] != nil {
                        playlistIds.insert(playlist.playlistId)
                    }
                }
                overlapByChannel[channelId] = (current.score + overlapScore, current.bestPlaylistId, current.sampleVideo, playlistIds)
            } else {
                let matchedPlaylistIds = Set(playlists.compactMap { playlistWeights[$0.playlistId] != nil ? $0.playlistId : nil })
                overlapByChannel[channelId] = (overlapScore, bestPlaylist.id, video, matchedPlaylistIds)
            }
        }

        return overlapByChannel
            .sorted { lhs, rhs in
                if lhs.value.score == rhs.value.score {
                    let lhsDate = CreatorAnalytics.parseISO8601Date(lhs.value.sampleVideo.publishedAt ?? "")
                    let rhsDate = CreatorAnalytics.parseISO8601Date(rhs.value.sampleVideo.publishedAt ?? "")
                    switch (lhsDate, rhsDate) {
                    case let (left?, right?) where left != right:
                        return left > right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    default:
                        return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                    }
                }
                return lhs.value.score > rhs.value.score
            }
            .prefix(limit)
            .compactMap { channelId, entry in
                guard adjacentCreatorMeetsAdmissionThreshold(score: entry.score, matchedPlaylistCount: entry.playlistIds.count) else { return nil }
                guard let channel = resolveChannelRecord(channelId: channelId, fallbackName: entry.sampleVideo.channelName, fallbackIconURL: entry.sampleVideo.channelIconUrl, store: store) else {
                    return nil
                }

                return ExploratoryChannelCandidate(
                    channel: channel,
                    affinity: max(Int(round(entry.score * 10)), 1),
                    sourceRef: entry.bestPlaylistId,
                    reasonHint: playlistTitles[entry.bestPlaylistId]
                )
            }
    }

    static func adjacentCreatorMeetsAdmissionThreshold(score: Double, matchedPlaylistCount: Int) -> Bool {
        if matchedPlaylistCount >= 2 {
            return score >= 1.4
        }
        return score >= 2.2
    }

    static func generatedSearchQueries(for topic: TopicViewModel) -> [String] {
        let base = topic.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [] }

        let currentYear = Calendar.current.component(.year, from: Date())
        let modifier = searchModifier(for: base)
        let raw = [
            base,
            "\(base) review",
            "\(base) \(currentYear)",
            "\(base) \(modifier)"
        ]

        var seen: Set<String> = []
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func searchModifier(for topicName: String) -> String {
        let lower = topicName.lowercased()
        if lower.contains("keyboard") { return "qmk" }
        if lower.contains("swift") || lower.contains("ios") || lower.contains("mac") || lower.contains("programming") || lower.contains("software") {
            return "tutorial"
        }
        if lower.contains("claude") || lower.contains("ai") || lower.contains("mcp") || lower.contains("automation") {
            return "news"
        }
        if lower.contains("gadget") || lower.contains("hardware") || lower.contains("review") {
            return "hands on"
        }
        return "update"
    }

    private static func isUsefulDiscoveryPlaylist(_ playlist: PlaylistRecord) -> Bool {
        if playlist.playlistId == "WL" { return false }
        let normalized = playlist.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "old watch" || normalized == "watch later" { return false }
        if normalized.contains("watch later") { return false }
        if normalized.contains("watch-later") { return false }
        if let videoCount = playlist.videoCount, videoCount > 800 { return false }
        return true
    }

    private static func resolveChannelRecord(channelId: String, fallbackName: String?, fallbackIconURL: String?, store: OrganizerStore) -> ChannelRecord? {
        if let existing = store.topicChannels.values.flatMap({ $0 }).first(where: { $0.channelId == channelId }) {
            return existing
        }
        if let fromStore = try? store.store.channelById(channelId) {
            return fromStore
        }
        guard let fallbackName, !fallbackName.isEmpty else { return nil }
        return ChannelRecord(channelId: channelId, name: fallbackName, channelUrl: "https://www.youtube.com/channel/\(channelId)", iconUrl: fallbackIconURL)
    }

    private static func shouldRefreshArchive(lastScannedAt: String?) -> Bool {
        guard let lastScannedAt,
              let scannedDate = CreatorAnalytics.parseISO8601Date(lastScannedAt) else {
            return true
        }
        return Date().timeIntervalSince(scannedDate) >= (12 * 60 * 60)
    }

    static func watchTopicAdmission(
        forTopic topicId: Int64,
        title: String,
        sourceKind: String,
        sourceRef: String,
        store: OrganizerStore
    ) -> WatchTopicAdmissionDecision {
        guard let topic = store.topics.first(where: { $0.id == topicId }) else {
            return .reject
        }

        let evidence = topicalEvidence(for: title, query: sourceRef, topic: topic)
        switch sourceKind {
        case "channel_archive_recent":
            guard evidence.knownCreatorQualifies else { return .reject }
            return WatchTopicAdmissionDecision(shouldAdmit: true, scoreBonus: evidence.scoreBonus)
        case "playlist_adjacent_recent", "search_query_recent":
            guard evidence.exploratoryQualifies else { return .reject }
            return WatchTopicAdmissionDecision(shouldAdmit: true, scoreBonus: evidence.scoreBonus)
        default:
            guard evidence.knownCreatorQualifies else { return .reject }
            return WatchTopicAdmissionDecision(shouldAdmit: true, scoreBonus: evidence.scoreBonus)
        }
    }

    static func topicalEvidence(for title: String, query: String, topic: TopicViewModel) -> WatchTopicalEvidence {
        let normalizedTitle = normalizeWatchText(title)
        let titleTokens = Set(normalizedTitle.split(separator: " ").map(String.init))
        let topicPhrase = normalizeWatchText(topic.name)
        let subtopicPhrases = topic.subtopics.map(\.name).map(normalizeWatchText)
        let topicTokens = significantTokens(in: topic.name)
        let subtopicTokens = Set(topic.subtopics.flatMap { significantTokens(in: $0.name) })
        let aliasPhrases = topicAliases[topic.name.lowercased(), default: []].map(normalizeWatchText)
        let aliasTokens = Set(aliasPhrases.flatMap { significantTokens(in: $0) })
        let normalizedQuery = normalizeWatchText(query)

        let topicPhraseMatched = !topicPhrase.isEmpty && normalizedTitle.contains(topicPhrase)
        let subtopicPhraseMatches = subtopicPhrases.filter { !$0.isEmpty && normalizedTitle.contains($0) }.count
        let aliasPhraseMatches = aliasPhrases.filter { !$0.isEmpty && normalizedTitle.contains($0) }.count
        let topicTokenMatches = titleTokens.intersection(topicTokens).count
        let subtopicTokenMatches = titleTokens.intersection(subtopicTokens).count
        let aliasTokenMatches = titleTokens.intersection(aliasTokens).count
        let queryTokenMatches = titleTokens.intersection(significantTokens(in: normalizedQuery)).count

        let score =
            (topicPhraseMatched ? 3 : 0) +
            subtopicPhraseMatches * 4 +
            aliasPhraseMatches * 3 +
            topicTokenMatches +
            subtopicTokenMatches * 2 +
            aliasTokenMatches * 2 +
            min(queryTokenMatches, 2)

        return WatchTopicalEvidence(
            score: score,
            topicPhraseMatched: topicPhraseMatched,
            subtopicPhraseMatches: subtopicPhraseMatches,
            aliasPhraseMatches: aliasPhraseMatches,
            topicTokenMatches: topicTokenMatches,
            subtopicTokenMatches: subtopicTokenMatches,
            aliasTokenMatches: aliasTokenMatches,
            queryTokenMatches: queryTokenMatches
        )
    }

    private static func normalizeWatchText(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func significantTokens(in value: String) -> Set<String> {
        Set(
            normalizeWatchText(value)
                .split(separator: " ")
                .map(String.init)
                .filter { token in
                    token.count >= 3 && !watchTopicStopwords.contains(token)
                }
        )
    }

    private static let watchTopicStopwords: Set<String> = [
        "and", "the", "for", "with", "from", "into", "your", "this", "that",
        "topic", "topics", "video", "videos", "review", "reviews", "update",
        "updates", "news", "guide", "guides", "tips", "best", "new", "systems",
        "tools", "digital", "history", "culture", "layouts", "techniques",
        "research", "industry", "current", "events", "learning", "interest",
        "personal", "growth", "life", "philosophy", "comparisons", "models"
    ]

    private static let topicAliases: [String: [String]] = [
        "mechanical keyboards": ["qmk", "via", "vial", "choc", "keycap", "switch", "handwired"],
        "macos & apple": ["macos", "mac", "apple", "macbook", "raycast", "alfred", "spotlight", "launchd"],
        "embedded systems": ["firmware", "esp32", "stm32", "arduino", "microcontroller", "gpio", "breadboard", "jtag", "pcb", "logic analyzer", "oscilloscope", "solder", "enclosure"],
        "vim & terminal": ["vim", "neovim", "nvim", "kitty", "ghostty", "tmux", "wezterm", "shell", "terminal"]
    ]
}

private struct CandidateSource: Hashable {
    let kind: String
    let ref: String
}

private struct CandidateChannelPlan {
    let channel: ChannelRecord
    let sourceKind: String
    let sourceRef: String
    let creatorAffinity: Int
    let reasonHint: String?
}

private struct ExploratoryChannelCandidate {
    let channel: ChannelRecord
    let affinity: Int
    let sourceRef: String
    let reasonHint: String?
}

private struct CandidateSearchPlan {
    let query: String
}

struct WatchTopicAdmissionDecision: Equatable {
    let shouldAdmit: Bool
    let scoreBonus: Int

    static let reject = WatchTopicAdmissionDecision(shouldAdmit: false, scoreBonus: 0)
}

struct WatchTopicalEvidence: Equatable {
    let score: Int
    let topicPhraseMatched: Bool
    let subtopicPhraseMatches: Int
    let aliasPhraseMatches: Int
    let topicTokenMatches: Int
    let subtopicTokenMatches: Int
    let aliasTokenMatches: Int
    let queryTokenMatches: Int

    var knownCreatorQualifies: Bool {
        topicPhraseMatched || subtopicPhraseMatches > 0 || aliasPhraseMatches > 0 || score >= 1
    }

    var exploratoryQualifies: Bool {
        topicPhraseMatched || subtopicPhraseMatches > 0 || aliasPhraseMatches > 0 || score >= 3
    }

    var scoreBonus: Int {
        min(score * 3, 18)
    }
}

private struct AggregatedCandidate {
    let videoId: String
    let title: String
    let channelId: String?
    let channelName: String?
    let viewCount: String?
    let publishedAt: String?
    let duration: String?
    let channelIconUrl: String?
    var score: Double
    var reason: String
    var sources: Set<CandidateSource>
}
