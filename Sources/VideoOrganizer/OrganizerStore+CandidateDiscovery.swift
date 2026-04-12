// OrganizerStore+CandidateDiscovery.swift
//
// Watch mode's candidate discovery, ranking, and pool management.
//
// Pipeline (runs on each Watch refresh cycle):
//   1. For each topic, build channel plans (core creators + playlist-adjacent
//      + exploratory search) via candidateChannelPlans / searchPlans
//   2. Scrape recent uploads for each channel via DiscoveryFallbackService
//   3. Score and accumulate candidates in accumulateCandidate (base score =
//      freshness + recencyBonus + creatorAffinity + qualityBonus + sourceBonus)
//   4. Persist scored candidates to topic_candidates SQLite table
//   5. rebuildWatchPools → rerankWatchVideos applies runtime adjustments:
//      - Recency boost (+1000 for today, decaying)
//      - Impression penalty (-40 per above-the-fold showing)
//      - Seen penalty (videos opened in-app)
//      - Creator repeat penalty (prevents one creator dominating)
//      - Favorite boost (+25 for pinned creators)
//   6. assignWatchVideosToTopics dedupes cross-topic and builds per-topic pools
//
// Key types:
//   CandidateVideoViewModel — view model for a single candidate card
//   AggregatedCandidate — intermediate during scoring (accumulates multi-source)
//   CandidateChannelPlan — which channels to scan for a topic
//   CandidateSearchPlan — which search queries to run for a topic

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
        rebuildWatchPools(trackImpressions: true)
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

            // Fix 3: skip the search lane entirely if the channel-archive pass already
            // produced enough candidates. Search is the most expensive discovery lane and
            // typically only matters when archives are sparse.
            let archiveCandidateThreshold = 24
            let archiveProducedEnough = aggregate.count >= archiveCandidateThreshold

            // Fix 4: per-topic 24h throttle on the search lane. Even if scraping is free,
            // re-running 4 search queries × 23 topics on every launch wastes work and
            // makes API fallback prompts cascade.
            let searchRecentlyAttempted = SearchAttemptLedger.shared.wasRecentlyAttempted(topicId: topicId)

            let searchPlans: [CandidateSearchPlan]
            if archiveProducedEnough {
                searchPlans = []
                AppLogger.discovery.info("Skipping search lane for topic \(topicId, privacy: .public): archive produced \(aggregate.count, privacy: .public) candidates (>= \(archiveCandidateThreshold, privacy: .public))")
            } else if searchRecentlyAttempted {
                searchPlans = []
                AppLogger.discovery.info("Skipping search lane for topic \(topicId, privacy: .public): attempted within last 24h")
            } else {
                searchPlans = CandidateDiscoveryCoordinator.searchPlans(for: topicId, store: self)
                if !searchPlans.isEmpty {
                    SearchAttemptLedger.shared.markAttempted(topicId: topicId)
                }
            }

            for plan in searchPlans {
                do {
                    let fallbackService = DiscoveryFallbackService(environment: runtimeEnvironment)
                    let results = try await fallbackService.searchVideos(query: plan.query, maxResults: 5)

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
                            creatorAffinity = 0
                        }
                        let resolvedIconUrl = video.channelId.flatMap { cid in
                            resolvedChannelRecord(channelId: cid, fallbackName: nil, fallbackIconURL: nil)?.iconUrl
                        }
                        // Convert fallback video to DiscoveredVideo-compatible accumulation
                        CandidateDiscoveryCoordinator.accumulateCandidate(
                            videoId: video.videoId,
                            title: video.title,
                            channelId: video.channelId,
                            channelName: video.channelTitle,
                            viewCount: video.viewCount,
                            publishedAt: video.publishedAt,
                            duration: video.duration,
                            channelIconUrl: resolvedIconUrl,
                            sourceKind: "search_query_recent",
                            sourceRef: plan.query,
                            creatorAffinity: creatorAffinity,
                            reasonHint: plan.query,
                            topicalEvidenceBonus: admission.scoreBonus,
                            existingVideoIds: existingVideoIds,
                            aggregate: &aggregate
                        )
                    }
                } catch {
                    // Scraper failed — try API if available
                    guard let youtubeClient else {
                        AppLogger.file.log("Search scraper failed for '\(plan.query)': \(error.localizedDescription)", category: "discovery")
                        continue
                    }

                    let approved = await requestAPIFallbackApproval(
                        kind: .search,
                        reason: "Search scraping failed for “\(plan.query)”.",
                        operation: .searchList
                    )
                    guard approved else {
                        AppLogger.file.log("Search API fallback denied for '\(plan.query)'", category: "discovery")
                        continue
                    }

                    do {
                        let results = try await youtubeClient.searchVideos(
                            query: plan.query, maxResults: 5, publishedAfterDays: 30
                        )
                        for video in results {
                            if let channelId = video.channelId, !channelId.isEmpty, isExcludedCreator(channelId) {
                                continue
                            }
                            let admission = CandidateDiscoveryCoordinator.watchTopicAdmission(
                                forTopic: topicId, title: video.title,
                                sourceKind: "search_query_recent", sourceRef: plan.query, store: self
                            )
                            guard admission.shouldAdmit else { continue }
                            let creatorAffinity = (try? store.videoCountForChannel(channelId: video.channelId ?? "", inTopic: topicId)) ?? 0
                            let resolvedIconUrl = video.channelId.flatMap { cid in
                                resolvedChannelRecord(channelId: cid, fallbackName: nil, fallbackIconURL: nil)?.iconUrl
                            }
                            CandidateDiscoveryCoordinator.accumulateCandidate(
                                video: video, sourceKind: "search_query_recent", sourceRef: plan.query,
                                creatorAffinity: creatorAffinity, reasonHint: plan.query,
                                topicalEvidenceBonus: admission.scoreBonus,
                                existingVideoIds: existingVideoIds, aggregate: &aggregate,
                                channelIconUrl: resolvedIconUrl
                            )
                        }
                    } catch {
                        AppLogger.file.log("Search failed for '\(plan.query)': scraper + API both failed", category: "discovery")
                    }
                }
            }

            let relatedSeedPlans = CandidateDiscoveryCoordinator.relatedSeedPlans(
                for: topicId,
                aggregate: aggregate,
                store: self
            )
            let relatedLaneThreshold = 24
            if aggregate.count < relatedLaneThreshold,
               browserExecutorReady,
               !relatedSeedPlans.isEmpty {
                do {
                    let browserResults = try await BrowserSyncService(environment: runtimeEnvironment)
                        .fetchRelatedVideos(
                            seedVideoIds: relatedSeedPlans.map(\.videoId),
                            maxResultsPerSeed: 4
                        )
                    let seedPlanByVideoId = Dictionary(uniqueKeysWithValues: relatedSeedPlans.map { ($0.videoId, $0) })

                    for video in browserResults {
                        guard let plan = seedPlanByVideoId[video.seedVideoId] else { continue }
                        if let channelId = video.channelId, !channelId.isEmpty, isExcludedCreator(channelId) {
                            continue
                        }
                        let admission = CandidateDiscoveryCoordinator.watchTopicAdmission(
                            forTopic: topicId,
                            title: video.title,
                            sourceKind: "browser_related_signed_in",
                            sourceRef: plan.evidenceRef,
                            store: self
                        )
                        guard admission.shouldAdmit else { continue }
                        let creatorAffinity = (try? store.videoCountForChannel(channelId: video.channelId ?? "", inTopic: topicId)) ?? 0
                        let resolvedIconUrl = video.channelId.flatMap { cid in
                            resolvedChannelRecord(channelId: cid, fallbackName: nil, fallbackIconURL: nil)?.iconUrl
                        }
                        CandidateDiscoveryCoordinator.accumulateCandidate(
                            videoId: video.videoId,
                            title: video.title,
                            channelId: video.channelId,
                            channelName: video.channelTitle,
                            viewCount: video.viewCount,
                            publishedAt: OrganizerStore.normalizePublishedAt(video.publishedAt, now: Date()),
                            duration: video.duration,
                            channelIconUrl: resolvedIconUrl,
                            sourceKind: "browser_related_signed_in",
                            sourceRef: plan.sourceRef,
                            relatedSeedSourceKind: plan.sourceKind,
                            creatorAffinity: creatorAffinity,
                            reasonHint: plan.reasonHint,
                            topicalEvidenceBonus: admission.scoreBonus,
                            existingVideoIds: existingVideoIds,
                            aggregate: &aggregate
                        )
                    }
                } catch {
                    AppLogger.file.log("Signed-in related discovery failed for topic \(topicId): \(error.localizedDescription)", category: "discovery")
                }
            }

            CandidateDiscoveryCoordinator.applyCreatorRelatedConsensusBonus(to: &aggregate)

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

    /// Fetches and caches channel icons for candidate creators missing face pile images.
    /// Phase 1a: Scrape channel pages for icon URLs (no quota needed).
    /// Phase 1b: Fall back to YouTube API for any the scraper missed.
    /// Phase 2: Download icon images from CDN (free, no quota).
    private func fetchMissingChannelIcons(from candidates: [TopicCandidate]) async {
        func log(_ msg: String) {
            AppLogger.discovery.info("\(msg, privacy: .public)")
            AppLogger.file.log(msg, category: "icons")
        }

        log("fetchMissingChannelIcons: \(candidates.count) candidates")

        var channelsWithUrl: [(channelId: String, iconUrl: URL, name: String)] = []
        var channelsWithoutUrl: [(channelId: String, name: String)] = []
        var seen = Set<String>()

        for candidate in candidates {
            guard let channelId = candidate.channelId, !channelId.isEmpty,
                  !seen.contains(channelId) else { continue }
            seen.insert(channelId)

            // Skip channels that already have icon data
            if let existing = knownChannelsById[channelId], existing.iconData != nil { continue }
            if let dbChannel = try? store.channelById(channelId), dbChannel.iconData != nil { continue }

            let name = candidate.channelName ?? "Unknown"
            if let iconUrlString = candidate.channelIconUrl, let iconUrl = URL(string: iconUrlString) {
                channelsWithUrl.append((channelId, iconUrl, name))
            } else {
                channelsWithoutUrl.append((channelId, name))
            }
        }

        log("Icon check: \(channelsWithUrl.count) with URL, \(channelsWithoutUrl.count) without URL")

        // Phase 1a: Scrape channel pages for icon URLs (no quota needed)
        if !channelsWithoutUrl.isEmpty {
            let scraped = await scrapeChannelIconURLs(channelIds: channelsWithoutUrl.map(\.channelId))
            for entry in channelsWithoutUrl {
                if let urlString = scraped[entry.channelId], let url = URL(string: urlString) {
                    channelsWithUrl.append((entry.channelId, url, entry.name))
                }
            }
            let scraperResolved = Set(scraped.keys)
            channelsWithoutUrl.removeAll { scraperResolved.contains($0.channelId) }
            log("Scrape resolved \(scraped.count) of \(channelsWithoutUrl.count + scraped.count) channel icons")
        }

        // Phase 1b: API fallback for channels scraper couldn't resolve
        if !channelsWithoutUrl.isEmpty, let youtubeClient {
            let approved = await requestAPIFallbackApproval(
                kind: .channelIcons,
                reason: "Missing \(channelsWithoutUrl.count) creator avatar\(channelsWithoutUrl.count == 1 ? "" : "s") after scraping.",
                operation: .channelsListSnippet
            )
            if approved {
                let ids = channelsWithoutUrl.map(\.channelId)
                do {
                    let thumbnailMap = try await youtubeClient.fetchChannelThumbnails(channelIds: ids)
                    for entry in channelsWithoutUrl {
                        if let urlString = thumbnailMap[entry.channelId], let url = URL(string: urlString) {
                            channelsWithUrl.append((entry.channelId, url, entry.name))
                        }
                    }
                    log("API resolved \(thumbnailMap.count) of \(ids.count) remaining channel icons")
                } catch {
                    log("API fallback failed: \(error.localizedDescription)")
                    if let ytError = error as? YouTubeError, ytError.isQuotaExceeded {
                        youtubeQuotaExhausted = true
                    }
                }
            } else {
                log("API fallback denied for remaining channel icons")
            }
        }

        guard !channelsWithUrl.isEmpty else { return }
        log("Downloading \(channelsWithUrl.count) channel icons from CDN")
        AppLogger.discovery.info("Downloading \(channelsWithUrl.count, privacy: .public) channel icons from CDN")

        // Phase 2: Download icon images from CDN (free, with per-icon timeout)
        var fetchedCount = 0
        for (channelId, iconUrl, name) in channelsWithUrl {
            do {
                let data = try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        let (data, response) = try await URLSession.shared.data(from: iconUrl)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                            throw CancellationError()
                        }
                        return data
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(4))
                        throw CancellationError()
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }

                if (try? store.channelById(channelId)) == nil {
                    try store.upsertChannel(ChannelRecord(
                        channelId: channelId,
                        name: name,
                        channelUrl: "https://www.youtube.com/channel/\(channelId)",
                        iconUrl: iconUrl.absoluteString
                    ))
                }
                try store.updateChannelIcon(channelId: channelId, iconData: data)
                knownChannelsById.removeValue(forKey: channelId)
                fetchedCount += 1
                log("  OK \(channelId) \(name) (\(data.count) bytes)")
            } catch {
                log("  FAIL \(channelId) \(name): \(error)")
            }
        }

        if fetchedCount > 0 {
            AppLogger.discovery.info("Cached \(fetchedCount, privacy: .public) channel icons")
            rebuildWatchPools()
        }
    }

    /// Scrapes YouTube channel pages for avatar URLs — no API quota needed.
    private func scrapeChannelIconURLs(channelIds: [String]) async -> [String: String] {
        guard !channelIds.isEmpty else { return [:] }
        await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
            kind: .channelIcons,
            backend: .scrape,
            outcome: .started,
            detail: "channel_count=\(channelIds.count)"
        )
        let scriptURL = runtimeEnvironment.scriptURL(named: "youtube_channel_icons.py")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            AppLogger.file.log("Channel icon scraper not found at \(scriptURL.path)", category: "icons")
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: .channelIcons,
                backend: .scrape,
                outcome: .failed,
                detail: "icon scraper missing"
            )
            return [:]
        }

        let bundledPython = runtimeEnvironment.repoRoot()
            .appendingPathComponent(".runtime/discovery-venv/bin/python3")
        let pythonPath = FileManager.default.isExecutableFile(atPath: bundledPython.path)
            ? bundledPython.path
            : "/usr/bin/python3"

        let process = Process()
        process.currentDirectoryURL = runtimeEnvironment.repoRoot()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            pythonPath,
            scriptURL.path,
            "--channel-ids", channelIds.joined(separator: ",")
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            let (stdoutData, stderrData) = try await withThrowingTaskGroup(of: (Data, Data).self) { group in
                group.addTask {
                    await withCheckedContinuation { continuation in
                        process.terminationHandler = { _ in
                            let out = stdout.fileHandleForReading.readDataToEndOfFile()
                            let err = stderr.fileHandleForReading.readDataToEndOfFile()
                            continuation.resume(returning: (out, err))
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    process.terminate()
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            guard process.terminationStatus == 0 else {
                let errText = String(data: stderrData, encoding: .utf8) ?? ""
                let sanitized = errText.replacingOccurrences(of: "\n", with: " | ").prefix(1000)
                AppLogger.file.log("Scraper exited \(process.terminationStatus): \(sanitized)", category: "icons")
                await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                    kind: .channelIcons,
                    backend: .scrape,
                    outcome: .failed,
                    detail: "exit=\(process.terminationStatus) \(sanitized)"
                )
                return [:]
            }

            struct Response: Decodable { let icons: [String: String] }
            let response = try JSONDecoder().decode(Response.self, from: stdoutData)
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: .channelIcons,
                backend: .scrape,
                outcome: .succeeded,
                detail: "resolved=\(response.icons.count) requested=\(channelIds.count)"
            )
            return response.icons
        } catch {
            AppLogger.file.log("Channel icon scraper failed: \(error.localizedDescription)", category: "icons")
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: .channelIcons,
                backend: .scrape,
                outcome: .failed,
                detail: error.localizedDescription
            )
            return [:]
        }
    }

    func ensureCandidatesForWatchPage() {
        AppLogger.file.log("ensureCandidatesForWatchPage called, task=\(watchRefreshTask == nil ? "nil" : "exists")", category: "discovery")
        guard watchRefreshTask == nil else { return }

        let topicsToRefresh = topics

        // Fast path: if all topics have fresh candidates, skip the refresh entirely
        let allFresh = topicsToRefresh.allSatisfy { CandidateDiscoveryCoordinator.shouldUseCachedCandidates(for: $0.id, store: self) }
        if allFresh && !storedCandidateVideosByTopic.isEmpty {
            AppLogger.file.log("All \(topicsToRefresh.count) topics have fresh candidates — skipping refresh", category: "discovery")
            rebuildWatchPools()
            return
        }
        watchRefreshTotalTopics = topicsToRefresh.count
        watchRefreshCompletedTopics = 0
        watchRefreshCurrentTopicName = selectedTopicId.flatMap { topicId in
            topicsToRefresh.first(where: { $0.id == topicId })?.name
        } ?? topicsToRefresh.first?.name

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.beginAPIFallbackPass()
            defer {
                self.endAPIFallbackPass()
                self.watchRefreshTask = nil
                self.watchRefreshTotalTopics = 0
                self.watchRefreshCompletedTopics = 0
                self.watchRefreshCurrentTopicName = nil
            }

            var remainingTopicIds = Set(topicsToRefresh.map(\.id))

            while !remainingTopicIds.isEmpty && !Task.isCancelled {
                let orderedIds = self.prioritizedWatchRefreshTopicIDs(from: Array(remainingTopicIds))
                guard let nextTopicId = orderedIds.first,
                      let topic = topicsToRefresh.first(where: { $0.id == nextTopicId }) else {
                    break
                }
                remainingTopicIds.remove(nextTopicId)
                AppLogger.file.log("Watch refresh: \(topic.name) (\(self.watchRefreshCompletedTopics)/\(topicsToRefresh.count)), remaining=\(remainingTopicIds.count)", category: "discovery")
                self.watchRefreshCurrentTopicName = topic.name

                if !CandidateDiscoveryCoordinator.shouldUseCachedCandidates(for: topic.id, store: self) {
                    await self.ensureCandidates(for: topic.id)
                } else {
                    // Even with cached candidates, fetch icons for channels that are missing them
                    let cached = (try? self.store.candidatesForTopic(id: topic.id, limit: 36)) ?? []
                    await self.fetchMissingChannelIcons(from: cached)
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

        // Phase 3: pinned creators get a flat additive boost in the watch ranking.
        // The boost is large enough to noticeably reorder results but smaller than
        // the existing source-kind weights so a low-quality favorited video can't
        // displace a high-evidence non-favorited one.
        let favoriteIds = Set(store.favoriteCreators.map(\.channelId))
        let favoriteBoost: Double = 25.0

        for video in prelim {
            let creatorKey = (video.channelId?.isEmpty == false ? video.channelId : video.channelName) ?? "unknown"
            let seenPenalty = appSeenPenalty(for: video, store: store)
            let repeatPenalty = creatorRepeatPenalty(for: video, currentCount: creatorCounts[creatorKey] ?? 0)
            let pinnedBoost: Double = (video.channelId.map { favoriteIds.contains($0) } ?? false) ? favoriteBoost : 0
            let recencyBoost = recencyBoostForReranking(publishedAt: video.publishedAt)
            let impressionPenalty = impressionPenaltyForReranking(videoId: video.videoId, store: store)
            let adjusted = video.score - seenPenalty - repeatPenalty + pinnedBoost + recencyBoost - impressionPenalty
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

    static func relatedSeedPlans(
        for topicId: Int64,
        aggregate: [String: AggregatedCandidate],
        store: OrganizerStore
    ) -> [CandidateRelatedSeedPlan] {
        let maxSeeds = 4
        var plans: [CandidateRelatedSeedPlan] = []
        var seenVideoIds: Set<String> = []
        var seenChannelIds: Set<String> = []
        let sortedCandidates = aggregate.values.sorted(by: rankedCandidatePrecedence)

        for preferredSourceKind in preferredSeedSourceKinds {
            guard let candidate = sortedCandidates.first(where: { candidate in
                candidate.sources.contains(where: { $0.kind == preferredSourceKind })
                    && seedCandidateIsUsable(candidate, seenVideoIds: seenVideoIds, seenChannelIds: seenChannelIds)
            }) else {
                continue
            }
            plans.append(seedPlan(for: candidate, preferredSourceKind: preferredSourceKind))
            seenVideoIds.insert(candidate.videoId)
            if let channelId = candidate.channelId, !channelId.isEmpty {
                seenChannelIds.insert(channelId)
            }
            if plans.count >= maxSeeds { return plans }
        }

        for candidate in sortedCandidates {
            guard seedCandidateIsUsable(candidate, seenVideoIds: seenVideoIds, seenChannelIds: seenChannelIds) else { continue }
            plans.append(seedPlan(for: candidate, preferredSourceKind: nil))
            seenVideoIds.insert(candidate.videoId)
            if let channelId = candidate.channelId, !channelId.isEmpty {
                seenChannelIds.insert(channelId)
            }
            if plans.count >= maxSeeds { return plans }
        }

        for video in store.videosForTopicIncludingSubtopics(topicId).sorted(by: rankedSavedSeedPrecedence) {
            guard !seenVideoIds.contains(video.videoId) else { continue }
            if let channelId = video.channelId, !channelId.isEmpty {
                guard seenChannelIds.insert(channelId).inserted else { continue }
            }
            seenVideoIds.insert(video.videoId)
            plans.append(
                CandidateRelatedSeedPlan(
                    videoId: video.videoId,
                    sourceRef: video.videoId,
                    evidenceRef: video.title,
                    reasonHint: video.title,
                    sourceKind: "saved_topic_recent"
                )
            )
            if plans.count >= maxSeeds { break }
        }

        if plans.count < maxSeeds {
            for video in store.videosForTopicIncludingSubtopics(topicId).sorted(by: rankedSavedSeedPrecedence) {
                guard seenVideoIds.insert(video.videoId).inserted else { continue }
                plans.append(
                    CandidateRelatedSeedPlan(
                        videoId: video.videoId,
                        sourceRef: video.videoId,
                        evidenceRef: video.title,
                        reasonHint: video.title,
                        sourceKind: "saved_topic_recent"
                    )
                )
                if plans.count >= maxSeeds { break }
            }
        }

        return plans
    }

    /// Recency boost applied at rerank time. Only trusts ISO 8601 dates
    /// for the full boost — relative strings like "today" or "5 days ago"
    /// were correct at scrape time but become stale across sessions (a
    /// video scraped as "today" three days ago is actually 3 days old,
    /// not 0 days). Relative dates get a capped moderate boost at best.
    private static func recencyBoostForReranking(publishedAt: String?) -> Double {
        guard let publishedAt else { return 0 }

        // ISO 8601 dates: trustworthy — we can compute exact age
        if let date = CreatorAnalytics.parseISO8601Date(publishedAt) {
            let ageDays = max(0, Int(Date().timeIntervalSince(date) / 86_400))
            switch ageDays {
            case ...1:   return 1000
            case ...3:   return 800
            case ...7:   return 500
            case ...14:  return 200
            case ...30:  return 100
            case ...90:  return 30
            default:     return 0
            }
        }

        // Relative date strings ("today", "5 days ago"): frozen at scrape
        // time. A video stored as "today" days ago keeps returning 0 from
        // parseAge, giving it a permanent max boost. Cap these at a
        // moderate 150 so they don't dominate the feed indefinitely.
        let ageDays = CreatorAnalytics.parseAge(publishedAt)
        guard ageDays != .max else { return 0 }
        return max(0, 150 - Double(ageDays) * 15)
    }

    /// Penalty for repeatedly-shown videos. Each impression subtracts 150
    /// points, capped at 1200. After 8 impressions even a today-video
    /// with +1000 recency boost drops below zero effective. This forces
    /// the feed to rotate: videos the user has seen 5+ times across
    /// sessions sink hard, making room for less-exposed candidates.
    private static func impressionPenaltyForReranking(videoId: String, store: OrganizerStore) -> Double {
        let count = store.watchImpressionCounts[videoId] ?? 0
        guard count > 0 else { return 0 }
        return min(Double(count) * 150, 1200)
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

    /// Backfills viewCount/duration/publishedAt for channel-archive scrape results that
    /// degraded to the RSS path. Returns an empty map if there is nothing to enrich,
    /// no API key configured, or the enrichment call fails. Costs 1 unit per call.
    static func enrichRSSFallbackMetadataIfNeeded(
        videos: [DiscoveryFallbackVideo],
        channelId: String,
        youtubeClient: YouTubeClient?
    ) async -> [String: VideoMetadata] {
        guard let youtubeClient else { return [:] }
        let needsEnrichment = videos.contains { video in
            video.source == "rss" && (video.viewCount == nil || video.duration == nil)
        }
        guard needsEnrichment else { return [:] }

        let videoIds = videos
            .filter { $0.source == "rss" && ($0.viewCount == nil || $0.duration == nil) }
            .map(\.videoId)
        guard !videoIds.isEmpty else { return [:] }

        await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
            kind: .channelArchive,
            backend: .api,
            outcome: .started,
            detail: "rss enrichment channel_id=\(channelId) videos=\(videoIds.count)"
        )

        do {
            let metadata = try await youtubeClient.fetchVideoMetadata(ids: videoIds)
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: .channelArchive,
                backend: .api,
                outcome: .succeeded,
                detail: "rss enrichment resolved \(metadata.count) of \(videoIds.count)"
            )
            return Dictionary(uniqueKeysWithValues: metadata.map { ($0.videoId, $0) })
        } catch {
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: .channelArchive,
                backend: .api,
                outcome: .failed,
                detail: "rss enrichment failed: \(error.localizedDescription)"
            )
            return [:]
        }
    }

    static func refreshChannelArchiveIfNeeded(channel: ChannelRecord, youtubeClient: YouTubeClient?, store: OrganizerStore) async throws -> [ArchivedChannelVideo] {
        let existingArchive = try store.store.archivedVideosForChannels([channel.channelId], perChannelLimit: 24)
        let knownVideoIDs = try store.store.archivedVideoIDsForChannel(channel.channelId)
        let lastScannedAt = try store.store.channelDiscoveryLastScannedAt(channelId: channel.channelId)
        guard shouldRefreshArchive(lastScannedAt: lastScannedAt) else {
            return existingArchive
        }

        // Scraper-first: try scraping channel uploads (no quota), fall back to API
        do {
            let recent = try await DiscoveryFallbackService(environment: store.runtimeEnvironment)
                .fetchRecentChannelUploads(channelId: channel.channelId, maxResults: 16)
                .filter { !knownVideoIDs.contains($0.videoId) }

            // RSS-fallback enrichment: when the scraper degraded to RSS, viewCount and
            // duration come back nil. A single videos.list call (1 unit per batch of 50)
            // backfills them. This is intentionally not gated by approval — it only fires
            // after a successful but degraded scrape, costs 1 unit per channel, and the
            // alternative is permanent missing metadata that hurts ranking and UX.
            let metadataMap = await enrichRSSFallbackMetadataIfNeeded(
                videos: recent,
                channelId: channel.channelId,
                youtubeClient: youtubeClient
            )

            let scannedAt = ISO8601DateFormatter().string(from: Date())
            let now = Date()
            let archived = recent.map { video -> ArchivedChannelVideo in
                let metadata = metadataMap[video.videoId]
                // Phase 3 fix: scrapetube returns relative-date strings ("5 years
                // ago") which break date parsing downstream. Normalize via the
                // shared helper. API metadata wins when present (it's already
                // ISO 8601), then scrapetube relative date, then nil.
                let publishedRaw = metadata?.formattedDate ?? video.publishedAt
                let publishedNormalized = OrganizerStore.normalizePublishedAt(publishedRaw, now: now)
                return ArchivedChannelVideo(
                    channelId: channel.channelId,
                    videoId: video.videoId,
                    title: video.title,
                    channelName: video.channelTitle ?? channel.name,
                    publishedAt: publishedNormalized,
                    duration: metadata?.formattedDuration ?? video.duration,
                    viewCount: metadata?.formattedViewCount ?? video.viewCount,
                    channelIconUrl: channel.iconUrl,
                    fetchedAt: scannedAt
                )
            }
            try store.store.upsertChannelDiscoveryArchive(channelId: channel.channelId, videos: archived, scannedAt: scannedAt)
            return try store.store.archivedVideosForChannels([channel.channelId], perChannelLimit: 200)
        } catch {
            // Scraper failed — fall back to YouTube API if available
            guard let youtubeClient else { throw error }

            let approved = await store.requestAPIFallbackApproval(
                kind: .channelArchive,
                reason: "Scraping failed for \(channel.name).",
                operation: .channelArchiveRefresh
            )
            guard approved else { return existingArchive }

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
        }
    }

    fileprivate static func accumulateCandidate(
        video: ArchivedChannelVideo,
        channel: ChannelRecord,
        sourceKind: String,
        sourceRef: String,
        relatedSeedSourceKind: String? = nil,
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
            relatedSeedSourceKind: relatedSeedSourceKind,
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
        relatedSeedSourceKind: String? = nil,
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
            relatedSeedSourceKind: relatedSeedSourceKind,
            creatorAffinity: creatorAffinity,
            reasonHint: reasonHint,
            topicalEvidenceBonus: topicalEvidenceBonus,
            existingVideoIds: existingVideoIds,
            aggregate: &aggregate
        )
    }

    fileprivate static func accumulateCandidate(
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
        relatedSeedSourceKind: String? = nil,
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
        case "browser_related_signed_in":
            sourceScore = (9, 1, 10)
            if let reasonHint, !reasonHint.isEmpty {
                reason = "Signed-in related suggestion from topic seed \(reasonHint)"
            } else {
                reason = "Signed-in related suggestion from a topic seed"
            }
        default:
            sourceScore = (4, 2, 0)
            reason = "Recent candidate from a related creator"
        }

        let score = Double(sourceScore.freshness + recencyBonus * 4 + creatorBonus * sourceScore.creatorWeight + qualityBonus + sourceScore.bonus + topicalEvidenceBonus)
        let relatedSeedVideoIds: Set<String> = sourceKind == "browser_related_signed_in" ? [sourceRef] : []
        let relatedSeedSourceKinds: Set<String> = {
            guard sourceKind == "browser_related_signed_in", let relatedSeedSourceKind, !relatedSeedSourceKind.isEmpty else { return [] }
            return [relatedSeedSourceKind]
        }()

        if var existing = aggregate[videoId] {
            existing.score += score + 3
            existing.relatedSeedVideoIds.formUnion(relatedSeedVideoIds)
            existing.relatedSeedSourceKinds.formUnion(relatedSeedSourceKinds)
            existing.score += relatedSeedConsensusBonus(
                seedCount: existing.relatedSeedVideoIds.count,
                seedSourceKindCount: existing.relatedSeedSourceKinds.count
            )
            let nowHasCoreSource = existing.sources.contains(where: { $0.kind == "channel_archive_recent" }) || sourceKind == "channel_archive_recent"
            let nowHasAdjacentSource = existing.sources.contains(where: { $0.kind == "playlist_adjacent_recent" }) || sourceKind == "playlist_adjacent_recent"
            let nowHasSearchSource = existing.sources.contains(where: { $0.kind == "search_query_recent" }) || sourceKind == "search_query_recent"
            let nowHasRelatedSource = existing.sources.contains(where: { $0.kind == "browser_related_signed_in" }) || sourceKind == "browser_related_signed_in"
            if nowHasCoreSource && nowHasAdjacentSource {
                existing.reason = "Fresh upload connected to this topic and your saved playlists"
            } else if nowHasCoreSource && nowHasSearchSource {
                existing.reason = "Fresh upload from a topic creator that also matched a topic search"
            } else if nowHasCoreSource && nowHasRelatedSource {
                existing.reason = "Fresh upload from a topic creator reinforced by signed-in related suggestions"
            } else if sourceKind == "playlist_adjacent_recent" {
                existing.reason = reason
            } else if sourceKind == "search_query_recent" {
                existing.reason = reason
            } else if sourceKind == "browser_related_signed_in" {
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
            sources: [CandidateSource(kind: sourceKind, ref: sourceRef)],
            relatedSeedVideoIds: relatedSeedVideoIds,
            relatedSeedSourceKinds: relatedSeedSourceKinds
        )
    }

    static func relatedSeedConsensusBonus(seedCount: Int, seedSourceKindCount: Int) -> Double {
        guard seedCount >= 2 else { return 0 }
        let repeatedSeedBonus = Double((seedCount - 1) * 10)
        let mixedSourceBonus = seedSourceKindCount >= 2 ? 8.0 : 0
        return repeatedSeedBonus + mixedSourceBonus
    }

    static func creatorRelatedConsensusBonus(seedCount: Int, seedSourceKindCount: Int) -> Double {
        guard seedCount >= 2 else { return 0 }
        let repeatedSeedBonus = Double((seedCount - 1) * 6)
        let mixedSourceBonus = seedSourceKindCount >= 2 ? 4.0 : 0
        return repeatedSeedBonus + mixedSourceBonus
    }

    static func applyCreatorRelatedConsensusBonus(to aggregate: inout [String: AggregatedCandidate]) {
        var creatorSeedVideoIds: [String: Set<String>] = [:]
        var creatorSeedSourceKinds: [String: Set<String>] = [:]

        for candidate in aggregate.values {
            guard let creatorKey = creatorConsensusKey(channelId: candidate.channelId, channelName: candidate.channelName) else { continue }
            guard !candidate.relatedSeedVideoIds.isEmpty else { continue }
            creatorSeedVideoIds[creatorKey, default: []].formUnion(candidate.relatedSeedVideoIds)
            creatorSeedSourceKinds[creatorKey, default: []].formUnion(candidate.relatedSeedSourceKinds)
        }

        for (videoId, candidate) in aggregate {
            guard let creatorKey = creatorConsensusKey(channelId: candidate.channelId, channelName: candidate.channelName),
                  let seedIds = creatorSeedVideoIds[creatorKey],
                  seedIds.count >= 2 else {
                continue
            }
            let seedSourceKinds = creatorSeedSourceKinds[creatorKey, default: []]
            var updated = candidate
            updated.score += creatorRelatedConsensusBonus(
                seedCount: seedIds.count,
                seedSourceKindCount: seedSourceKinds.count
            )
            aggregate[videoId] = updated
        }
    }

    private static func creatorConsensusKey(channelId: String?, channelName: String?) -> String? {
        if let channelId, !channelId.isEmpty {
            return "id:\(channelId)"
        }
        if let channelName {
            let normalized = channelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                return "name:\(normalized)"
            }
        }
        return nil
    }

    static func friendlyCandidateErrorMessage(for error: Error) -> String {
        if let youtubeError = error as? YouTubeError, youtubeError.isQuotaExceeded {
            return "YouTube API quota is exhausted for today. Existing saved videos still work, and candidate discovery will work again after quota resets at midnight Pacific."
        }
        return error.localizedDescription
    }

    static func presentQuotaAlertIfNeeded(for error: Error, store: OrganizerStore) {
        guard let youtubeError = error as? YouTubeError, youtubeError.isQuotaExceeded else { return }
        store.youtubeQuotaExhausted = true
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

    private static func rankedCandidatePrecedence(_ lhs: AggregatedCandidate, _ rhs: AggregatedCandidate) -> Bool {
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

    private static func rankedSavedSeedPrecedence(_ lhs: VideoViewModel, _ rhs: VideoViewModel) -> Bool {
        let now = Date()
        let lhsDate = CreatorAnalytics.parseISO8601Date(OrganizerStore.normalizePublishedAt(lhs.publishedAt, now: now) ?? "")
        let rhsDate = CreatorAnalytics.parseISO8601Date(OrganizerStore.normalizePublishedAt(rhs.publishedAt, now: now) ?? "")
        switch (lhsDate, rhsDate) {
        case let (l?, r?) where l != r:
            return l > r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let lhsViews = CreatorAnalytics.parseViewCount(lhs.viewCount ?? "")
            let rhsViews = CreatorAnalytics.parseViewCount(rhs.viewCount ?? "")
            if lhsViews != rhsViews {
                return lhsViews > rhsViews
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static let preferredSeedSourceKinds = [
        "channel_archive_recent",
        "search_query_recent",
        "playlist_adjacent_recent"
    ]

    private static func seedCandidateIsUsable(
        _ candidate: AggregatedCandidate,
        seenVideoIds: Set<String>,
        seenChannelIds: Set<String>
    ) -> Bool {
        guard !seenVideoIds.contains(candidate.videoId) else { return false }
        if let channelId = candidate.channelId, !channelId.isEmpty, seenChannelIds.contains(channelId) {
            return false
        }
        // Do not recursively reseed from related-only discoveries. Prefer candidates
        // that were admitted through stronger archive/search/adjacent evidence.
        return candidate.sources.contains { $0.kind != "browser_related_signed_in" }
    }

    private static func seedPlan(
        for candidate: AggregatedCandidate,
        preferredSourceKind: String?
    ) -> CandidateRelatedSeedPlan {
        let matchedSourceKind = preferredSourceKind
            ?? preferredSeedSourceKinds.first(where: { kind in
                candidate.sources.contains(where: { $0.kind == kind })
            })
            ?? "mixed_candidate_recent"
        return CandidateRelatedSeedPlan(
            videoId: candidate.videoId,
            sourceRef: candidate.videoId,
            evidenceRef: candidate.title,
            reasonHint: candidate.title,
            sourceKind: matchedSourceKind
        )
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
        case "playlist_adjacent_recent", "search_query_recent", "browser_related_signed_in":
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

struct CandidateSource: Hashable {
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

struct CandidateRelatedSeedPlan {
    let videoId: String
    let sourceRef: String
    let evidenceRef: String
    let reasonHint: String?
    let sourceKind: String
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

struct AggregatedCandidate {
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
    var relatedSeedVideoIds: Set<String> = []
    var relatedSeedSourceKinds: Set<String> = []
}
