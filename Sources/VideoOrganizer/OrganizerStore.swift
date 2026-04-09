import AppKit
import Foundation
import Observation
import TaggingKit

/// Central application state bridging TaggingKit's SQLite backend to SwiftUI via Observation.
///
/// Owns the ``TopicStore`` database connection and exposes materialized caches
/// (video maps, channel data, watch pools) that views bind to. Mutations flow
/// through store methods which update the database, rebuild caches, and let
/// SwiftUI pick up changes automatically via `@Observable`.
///
/// Extended by:
/// - `OrganizerStore+CandidateDiscovery` — Watch candidate fetching and ranking
/// - `OrganizerStore+Sync` — YouTube playlist sync queue
/// - `OrganizerStore+CreatorAnalytics` — Channel-level aggregation
/// - `OrganizerStore+SeenHistory` — Watch history import
@MainActor
@Observable
final class OrganizerStore {
    /// All top-level topics with their subtopics. Rebuilt on every `loadTopics()` call.
    private(set) var topics: [TopicViewModel] = []
    private(set) var totalVideoCount: Int = 0
    private(set) var unassignedCount: Int = 0
    private(set) var isLoading = false
    var errorMessage: String?
    var alert: AppAlertState?
    /// Incremented to signal views that candidate data has changed externally.
    var candidateRefreshToken = 0
    /// Incremented when the ranked watch pool is rebuilt; used as a `.task(id:)` key.
    var watchPoolVersion = 0
    var syncQueueSummary = SyncQueueSummary(queued: 0, retrying: 0, deferred: 0, inProgress: 0, browserDeferred: 0)
    var lastSyncErrorMessage: String?
    var lastSyncErrorIsBrowser = false
    var seenHistoryCount = 0
    var excludedCreators: [ExcludedChannelRecord] = []
    var browserExecutorReady = false
    var browserExecutorStatusMessage = "Checking browser executor status…"
    var topicScrollProgress = 0.0
    var viewportTopicId: Int64?
    var viewportSubtopicId: Int64?
    var viewportCreatorSectionId: String?
    var visibleWatchTopicIds: [Int64] = []

    // Selected state
    var selectedTopicId: Int64? {
        didSet {
            if oldValue != selectedTopicId {
                selectedChannelId = nil
                inspectedCreatorName = nil
                topicScrollProgress = 0
            }
        }
    }
    var selectedSubtopicId: Int64?
    var selectedVideoId: String? {
        didSet {
            if selectedVideoId != nil, oldValue != selectedVideoId {
                inspectedCreatorName = nil
            }
            if !isUpdatingSelectionFromGrid {
                if let selectedVideoId {
                    selectedVideoIds = [selectedVideoId]
                } else {
                    selectedVideoIds = []
                }
            }
        }
    }
    private(set) var selectedVideoIds: Set<String> = []
    var hoveredVideoId: String?

    // Channel / playlist filters
    var selectedChannelId: String?
    var selectedPlaylistId: String?
    var selectedPlaylistTitle: String?

    // Creator inspection — set when hovering/clicking a creator section header
    var inspectedCreatorName: String?

    // Search
    var searchText: String = ""
    var parsedQuery: SearchQuery { SearchQuery(searchText) }
    var searchResultCount: Int = 0

    // Page-level center-pane mode
    var pageDisplayMode: TopicDisplayMode = .saved
    var watchPresentationMode: WatchPresentationMode = .byTopic
    var candidateErrors: [Int64: String] = [:]
    var candidateLoadingTopics: Set<Int64> = []
    var candidateProgressByTopic: [Int64: Double] = [:]
    var candidateCompletedChannelsByTopic: [Int64: Int] = [:]
    var candidateTotalChannelsByTopic: [Int64: Int] = [:]
    var candidateCurrentChannelNameByTopic: [Int64: String] = [:]
    var watchRefreshCompletedTopics = 0
    var watchRefreshTotalTopics = 0
    var watchRefreshCurrentTopicName: String?
    private(set) var watchPoolByTopic: [Int64: [CandidateVideoViewModel]] = [:]
    private(set) var rankedWatchPool: [CandidateVideoViewModel] = []
    private(set) var storedCandidateVideosByTopic: [Int64: [CandidateVideoViewModel]] = [:]

    // Cached flat video map — rebuilt on loadTopics()
    var videoMap: [String: VideoViewModel] = [:]
    var videoTopicMap: [String: Int64] = [:]
    private(set) var topicSearchFields: [Int64: [String]] = [:]
    var syncTask: Task<Void, Never>?
    var browserSyncTask: Task<Void, Never>?
    var syncLoopTask: Task<Void, Never>?
    var browserStatusTask: Task<Void, Never>?
    var watchRefreshTask: Task<Void, Never>?
    private var watchPoolVersionSignalTask: Task<Void, Never>?
    private var isUpdatingSelectionFromGrid = false

    let store: TopicStore
    var suggester: TopicSuggester?
    var youtubeClient: YouTubeClient?
    let runtimeEnvironment: RuntimeEnvironment

    init(dbPath: String, claudeClient: ClaudeClient? = nil, startBackgroundTasks: Bool = true) throws {
        self.store = try TopicStore(path: dbPath)
        self.suggester = claudeClient.map { TopicSuggester(client: $0) }
        self.youtubeClient = try? YouTubeClient()
        self.runtimeEnvironment = RuntimeEnvironment()
        loadTopics()
        recoverInterruptedSyncActions(context: "startup")
        refreshSyncQueueSummary()
        refreshSeenHistoryCount()
        refreshExcludedCreators()
        if startBackgroundTasks {
            refreshBrowserExecutorStatus()
            processPendingSync(reason: "startup")
            processPendingBrowserSync(reason: "startup")
            startSyncLoop()
        } else {
            browserExecutorStatusMessage = "Background sync disabled"
        }
    }

    func refreshCredentialBackedClients() {
        let client = try? ClaudeClient()
        suggester = client.map { TopicSuggester(client: $0) }
        youtubeClient = try? YouTubeClient()
        AppLogger.auth.info("Refreshed credential-backed service clients")
    }

    func refreshExcludedCreators() {
        do {
            excludedCreators = try store.excludedChannelsList()
        } catch {
            AppLogger.app.error("Failed to load excluded creators: \(error.localizedDescription, privacy: .public)")
            excludedCreators = []
        }
    }

    // MARK: - Loading

    /// Reloads all topics from the database and rebuilds every derived cache
    /// (video maps, playlist maps, candidate caches, watch pools, sync summary).
    func loadTopics() {
        do {
            let summaries = try store.listTopics()
            topics = summaries.map { summary in
                let subtopicSummaries: [TopicSummary]
                do {
                    subtopicSummaries = try store.subtopicsForTopic(id: summary.id)
                } catch {
                    AppLogger.app.error("Failed to load subtopics for topic \(summary.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    subtopicSummaries = []
                }
                let subtopics = subtopicSummaries.map {
                    TopicViewModel(id: $0.id, name: $0.name, videoCount: $0.videoCount, parentId: summary.id)
                }
                return TopicViewModel(id: summary.id, name: summary.name, videoCount: summary.videoCount, subtopics: subtopics)
            }
            totalVideoCount = try store.totalVideoCount()
            unassignedCount = try store.unassignedCount()
            if selectedTopicId == nil, let first = topics.first {
                selectedTopicId = first.id
            }
            rebuildVideoMaps()
            rebuildPlaylistMaps()
            reloadStoredCandidateCaches()
            rebuildWatchPools()
            refreshSyncQueueSummary()
            refreshSeenHistoryCount()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Get videos for a topic including its subtopics.
    func videosForTopicIncludingSubtopics(_ topicId: Int64) -> [VideoViewModel] {
        do {
            let stored = try store.videosForTopicIncludingSubtopics(id: topicId)
            return stored.map { VideoViewModel(from: $0) }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func videosForTopic(_ topicId: Int64, limit: Int? = nil) -> [VideoViewModel] {
        do {
            let stored = try store.videosForTopic(id: topicId, limit: limit)
            return stored.map { VideoViewModel(from: $0) }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    // MARK: - Video Lookup (O(1) via cached map)

    /// The video currently shown in the inspector — hovered takes priority, else selected.
    var inspectedVideoId: String? {
        hoveredVideoId ?? selectedVideoId
    }

    var selectedVideos: [VideoViewModel] {
        selectedVideoIds.compactMap { videoMap[$0] }
    }

    var inspectedVideo: VideoViewModel? {
        inspectedVideoId.flatMap { videoMap[$0] }
    }

    var inspectedCandidateVideo: CandidateVideoViewModel? {
        guard let videoId = inspectedVideoId,
              let topicId = selectedTopicId,
              displayMode(for: topicId) == .watchCandidates,
              let stored = try? store.candidateForTopic(id: topicId, videoId: videoId)
        else {
            return nil
        }
        return CandidateVideoViewModel(from: stored)
    }

    var inspectedItem: InspectedVideoViewModel? {
        if let video = inspectedVideo {
            return InspectedVideoViewModel(
                video: video,
                playlists: playlistsForVideo(video.videoId),
                isWatchCandidate: false,
                seenSummary: seenSummary(for: video.videoId)
            )
        }

        if let candidate = inspectedCandidateVideo {
            return InspectedVideoViewModel(
                video: VideoViewModel(from: candidate),
                playlists: playlistsForVideo(candidate.videoId),
                isWatchCandidate: true,
                seenSummary: seenSummary(for: candidate.videoId)
            )
        }

        return nil
    }

    func videoById(_ videoId: String) -> VideoViewModel? {
        videoMap[videoId]
    }

    func updateSelection(primary: String?, all ids: Set<String>) {
        isUpdatingSelectionFromGrid = true
        selectedVideoIds = ids
        selectedVideoId = primary
        if primary != nil {
            inspectedCreatorName = nil
        }
        isUpdatingSelectionFromGrid = false
    }

    func topicNameForVideo(_ videoId: String) -> String? {
        guard let topicId = videoTopicMap[videoId] else { return nil }
        return topics.first { $0.id == topicId }?.name
    }

    func topicMatchesSearch(_ topic: TopicViewModel, query: SearchQuery) -> Bool {
        guard !query.isEmpty else { return true }
        return query.matches(fields: topicSearchFields[topic.id] ?? [topic.name])
    }

    func playlistsForVideo(_ videoId: String) -> [PlaylistRecord] {
        playlistsByVideoId[videoId] ?? []
    }

    func badgeTagForVideo(_ videoId: String, candidateState: String? = nil, topicId: Int64? = nil, channelId: String? = nil) -> String? {
        let playlists = playlistsByVideoId[videoId] ?? []
        if playlists.contains(where: { $0.playlistId == "WL" }) {
            return "Watch Later"
        }
        if candidateState == CandidateState.saved.rawValue {
            return "Saved"
        }
        if let topicId, let channelId, !channelId.isEmpty, isNewCreatorInTopic(channelId, topicId: topicId) {
            return "New Creator"
        }
        return nil
    }

    func isNewCreatorInTopic(_ channelId: String, topicId: Int64) -> Bool {
        !channelsForTopic(topicId).contains(where: { $0.channelId == channelId })
    }

    func seenSummary(for videoId: String) -> SeenVideoSummary? {
        try? store.seenSummary(videoId: videoId)
    }

    func channelPresentation(for video: VideoViewModel) -> ChannelPresentation {
        let channelRecord: ChannelRecord? =
            if let channelId = video.channelId {
                topicChannels.values
                    .flatMap { $0 }
                    .first(where: { $0.channelId == channelId })
            } else if let channelName = video.channelName {
                topicChannels.values
                    .flatMap { $0 }
                    .first(where: { $0.name == channelName })
            } else {
                nil
            }

        return ChannelPresentation(
            name: video.channelName ?? channelRecord?.name,
            channelUrl: channelRecord?.channelUrl ?? video.channelId.flatMap { "https://www.youtube.com/channel/\($0)" },
            iconUrl: channelRecord?.iconUrl ?? video.channelIconUrl,
            iconData: channelRecord?.iconData
        )
    }

    func videoIsInSelectedPlaylist(_ videoId: String) -> Bool {
        guard let selectedPlaylistId else { return true }
        return playlistsByVideoId[videoId]?.contains(where: { $0.playlistId == selectedPlaylistId }) ?? false
    }

    func applyPlaylistFilter(_ playlist: PlaylistRecord) {
        selectedPlaylistId = playlist.playlistId
        selectedPlaylistTitle = playlist.title
        selectedChannelId = nil
        selectedSubtopicId = nil
        AppLogger.discovery.info("Applied playlist filter \(playlist.playlistId, privacy: .public) (\(playlist.title, privacy: .public))")
    }

    func clearPlaylistFilter() {
        guard selectedPlaylistId != nil else { return }
        AppLogger.discovery.info("Cleared playlist filter \(self.selectedPlaylistId ?? "", privacy: .public)")
        selectedPlaylistId = nil
        selectedPlaylistTitle = nil
    }

    func moreFromChannel(videoId: String, limit: Int = 6) -> [VideoViewModel] {
        guard let video = videoMap[videoId] else { return [] }

        let matches = videoMap.values.filter { candidate in
            guard candidate.videoId != videoId else { return false }
            if let channelId = video.channelId, !channelId.isEmpty {
                return candidate.channelId == channelId
            }
            guard let channelName = video.channelName, !channelName.isEmpty else { return false }
            return candidate.channelName == channelName
        }

        let sorted = matches.sorted { lhs, rhs in
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
                if lhs.sourceIndex != rhs.sourceIndex {
                    return lhs.sourceIndex < rhs.sourceIndex
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }

        return Array(sorted.prefix(limit))
    }

    // Cached channel counts — rebuilt with video maps
    private(set) var channelCounts: [String: Int] = [:]
    var playlistsByVideoId: [String: [PlaylistRecord]] = [:]

    // Cached channels per topic — rebuilt on loadTopics()
    private(set) var topicChannels: [Int64: [ChannelRecord]] = [:]
    private(set) var knownChannelsById: [String: ChannelRecord] = [:]

    // Cached per-topic channel video counts: [topicId: [channelId: count]]
    var topicChannelCounts: [Int64: [String: Int]] = [:]

    // Cached per-topic channel recency: [topicId: Set<channelId>]
    var topicChannelRecent: [Int64: Set<String>] = [:]

    /// Returns channels with videos in the given topic (including subtopics), sorted by video count desc.
    func channelsForTopic(_ topicId: Int64) -> [ChannelRecord] {
        topicChannels[topicId] ?? []
    }

    func resolvedChannelRecord(
        channelId: String?,
        fallbackName: String?,
        fallbackIconURL: String?
    ) -> ChannelRecord? {
        if let channelId, !channelId.isEmpty {
            if let cached = knownChannelsById[channelId] {
                return cached
            }
            if let fromStore = ((try? store.channelById(channelId)) ?? nil) {
                knownChannelsById[channelId] = fromStore
                return fromStore
            }
            return ChannelRecord(
                channelId: channelId,
                name: fallbackName ?? "Unknown Creator",
                channelUrl: "https://www.youtube.com/channel/\(channelId)",
                iconUrl: fallbackIconURL
            )
        }

        guard let fallbackName, !fallbackName.isEmpty else { return nil }
        return ChannelRecord(
            channelId: "watch-\(fallbackName)",
            name: fallbackName,
            channelUrl: nil,
            iconUrl: fallbackIconURL
        )
    }

    /// Video count for a channel within a topic. O(1) from cache.
    func videoCountForChannel(_ channelId: String, inTopic topicId: Int64) -> Int {
        topicChannelCounts[topicId]?[channelId] ?? 0
    }

    /// Whether a channel has recent content in a topic. O(1) from cache.
    func channelHasRecentContent(_ channelId: String, inTopic topicId: Int64) -> Bool {
        topicChannelRecent[topicId]?.contains(channelId) ?? false
    }

    /// Toggle channel filter. If already selected, deselects.
    func toggleChannelFilter(_ channelId: String) {
        if selectedChannelId == channelId {
            selectedChannelId = nil
        } else {
            selectedChannelId = channelId
        }
    }

    /// Clear channel filter.
    func clearChannelFilter() {
        selectedChannelId = nil
    }

    func isExcludedCreator(_ channelId: String?) -> Bool {
        guard let channelId, !channelId.isEmpty else { return false }
        return excludedCreators.contains(where: { $0.channelId == channelId })
    }

    private var watchRecentWindowDays: Int { 30 }

    func isRecentWatchPublishedAt(_ publishedAt: String?) -> Bool {
        guard let date = watchPublishedDate(from: publishedAt) else { return false }
        return date >= Date().addingTimeInterval(TimeInterval(-watchRecentWindowDays * 86_400))
    }

    func watchPublishedDate(from publishedAt: String?) -> Date? {
        guard let publishedAt, !publishedAt.isEmpty else { return nil }
        if let iso = CreatorAnalytics.parseISO8601Date(publishedAt) {
            return iso
        }
        let ageDays = CreatorAnalytics.parseAge(publishedAt)
        guard ageDays != .max else { return nil }
        return Calendar.current.date(byAdding: .day, value: -ageDays, to: Date())
    }

    func recentCandidateVideosForTopic(_ topicId: Int64) -> [CandidateVideoViewModel] {
        watchPoolForTopic(topicId, applyingChannelFilter: false)
    }

    func recentStoredCandidateVideosForTopic(_ topicId: Int64) -> [CandidateVideoViewModel] {
        CandidateDiscoveryCoordinator.recentEligibleWatchVideos(
            storedCandidateVideosForTopic(topicId),
            store: self
        ).filter { candidate in
            !isExcludedCreator(candidate.channelId)
        }
    }

    func recentCandidateVideosForAllTopics() -> [CandidateVideoViewModel] {
        watchPoolForAllTopics(applyingChannelFilter: false)
    }

    func watchCandidateCountForChannel(_ channelId: String?, channelName: String?, inTopic topicId: Int64, recentOnly: Bool = true) -> Int {
        let candidates = recentOnly
            ? watchPoolForTopic(topicId, applyingChannelFilter: false)
            : storedCandidateVideosForTopic(topicId).filter { !$0.isPlaceholder }
        return watchCandidateCountForChannel(channelId, channelName: channelName, inCandidates: candidates)
    }

    func watchCandidateCountForChannel(_ channelId: String?, channelName: String?, inCandidates candidates: [CandidateVideoViewModel]) -> Int {
        candidates.filter { candidate in
            if let channelId, !channelId.isEmpty, candidate.channelId == channelId {
                return true
            }
            if let channelName, !channelName.isEmpty, candidate.channelName == channelName {
                return true
            }
            return false
        }.count
    }

    func latestWatchCandidateDateForChannel(_ channelId: String?, channelName: String?, inTopic topicId: Int64) -> Date? {
        latestWatchCandidateDateForChannel(
            channelId,
            channelName: channelName,
            inCandidates: watchPoolForTopic(topicId, applyingChannelFilter: false)
        )
    }

    func latestWatchCandidateDateForChannel(_ channelId: String?, channelName: String?, inCandidates candidates: [CandidateVideoViewModel]) -> Date? {
        candidates
        .filter { candidate in
            if let channelId, !channelId.isEmpty, candidate.channelId == channelId {
                return true
            }
            if let channelName, !channelName.isEmpty, candidate.channelName == channelName {
                return true
            }
            return false
        }
        .compactMap { watchPublishedDate(from: $0.publishedAt) }
        .max()
    }

    func hasRecentWatchCandidateContent(_ channelId: String?, channelName: String?, inTopic topicId: Int64) -> Bool {
        latestWatchCandidateDateForChannel(channelId, channelName: channelName, inTopic: topicId)
            .map { $0 >= Date().addingTimeInterval(TimeInterval(-watchRecentWindowDays * 86_400)) } ?? false
    }

    @discardableResult
    func navigateToCreatorInWatch(channelId: String?, channelName: String?, preferredTopicId: Int64? = nil) -> Int64? {
        let priorTopicId = selectedTopicId
        let priorChannelId = selectedChannelId
        let matchingTopics = topics.compactMap { topic -> Int64? in
            let count = watchCandidateCountForChannel(channelId, channelName: channelName, inTopic: topic.id, recentOnly: true)
            return count > 0 ? topic.id : nil
        }

        guard !matchingTopics.isEmpty else { return nil }

        let targetTopicId: Int64
        if let preferredTopicId, matchingTopics.contains(preferredTopicId) {
            targetTopicId = preferredTopicId
        } else if let selectedTopicId, matchingTopics.contains(selectedTopicId) {
            targetTopicId = selectedTopicId
        } else {
            targetTopicId = matchingTopics[0]
        }

        let normalizedChannelId = (channelId?.isEmpty == false) ? channelId : nil
        let targetCandidates = watchPoolForTopic(targetTopicId, applyingChannelFilter: false)
            .filter { candidate in
                if let normalizedChannelId, candidate.channelId == normalizedChannelId {
                    return true
                }
                if let channelName, !channelName.isEmpty, candidate.channelName == channelName {
                    return true
                }
                return false
            }

        clearPlaylistFilter()
        selectedSubtopicId = nil
        hoveredVideoId = nil
        selectedTopicId = targetTopicId

        let shouldClear = priorChannelId == normalizedChannelId && pageDisplayMode == .watchCandidates && priorTopicId == targetTopicId
        selectedChannelId = shouldClear ? nil : normalizedChannelId
        inspectedCreatorName = shouldClear ? nil : channelName
        selectedVideoId = shouldClear ? nil : targetCandidates.first?.videoId

        AppLogger.discovery.info("Navigated to watch creator \(channelName ?? "", privacy: .public) in topic \(targetTopicId, privacy: .public)")
        return targetTopicId
    }

    @discardableResult
    func navigateToCreator(channelId: String?, channelName: String?, preferredTopicId: Int64? = nil) -> Int64? {
        let matchingTopics = topics.compactMap { topic -> Int64? in
            let channels = channelsForTopic(topic.id)
            if let channelId, channels.contains(where: { $0.channelId == channelId }) {
                return topic.id
            }
            if let channelName, channels.contains(where: { $0.name == channelName }) {
                return topic.id
            }
            return nil
        }

        guard !matchingTopics.isEmpty else { return nil }

        let targetTopicId: Int64
        if let preferredTopicId, matchingTopics.contains(preferredTopicId) {
            targetTopicId = preferredTopicId
        } else if let selectedTopicId, matchingTopics.contains(selectedTopicId) {
            targetTopicId = selectedTopicId
        } else {
            targetTopicId = matchingTopics[0]
        }

        let channels = channelsForTopic(targetTopicId)
        let resolvedChannel = channels.first(where: { channel in
            if let channelId, channel.channelId == channelId { return true }
            if let channelName, channel.name == channelName { return true }
            return false
        })

        let targetVideos = videosForTopicIncludingSubtopics(targetTopicId)
            .filter { video in
                if let resolvedChannelId = resolvedChannel?.channelId {
                    return video.channelId == resolvedChannelId
                }
                if let channelId, !channelId.isEmpty {
                    return video.channelId == channelId
                }
                if let resolvedChannelName = resolvedChannel?.name {
                    return video.channelName == resolvedChannelName
                }
                if let channelName, !channelName.isEmpty {
                    return video.channelName == channelName
                }
                return false
            }
            .sorted { lhs, rhs in
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
                    if lhs.sourceIndex != rhs.sourceIndex {
                        return lhs.sourceIndex < rhs.sourceIndex
                    }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }

        clearPlaylistFilter()
        selectedSubtopicId = nil
        pageDisplayMode = .saved
        hoveredVideoId = nil
        selectedTopicId = targetTopicId
        selectedChannelId = resolvedChannel?.channelId ?? channelId
        inspectedCreatorName = resolvedChannel?.name ?? channelName
        selectedVideoId = targetVideos.first?.videoId

        AppLogger.discovery.info("Navigated to creator \(self.inspectedCreatorName ?? "", privacy: .public) in topic \(targetTopicId, privacy: .public)")
        return targetTopicId
    }

    func displayMode(for topicId: Int64) -> TopicDisplayMode {
        pageDisplayMode
    }

    func setPageDisplayMode(_ mode: TopicDisplayMode) {
        pageDisplayMode = mode
        AppLogger.discovery.info("Set page display mode to \(mode.rawValue, privacy: .public)")
        if mode == .watchCandidates {
            selectedPlaylistId = nil
            selectedPlaylistTitle = nil
            selectedChannelId = nil
            selectedSubtopicId = nil
            selectedVideoId = nil
            viewportTopicId = nil
            viewportSubtopicId = nil
            viewportCreatorSectionId = nil
            visibleWatchTopicIds = []
        }
        candidateRefreshToken += 1
    }

    /// Rebuilds the materialized watch pool from stored candidates.
    /// Filters by recency and excluded creators, deduplicates across topics,
    /// and reranks the combined pool. Increments `watchPoolVersion` to signal views.
    func rebuildWatchPools() {
        let startedAt = ContinuousClock.now
        let perTopic = Dictionary(uniqueKeysWithValues: topics.map { topic in
            (
                topic.id,
                CandidateDiscoveryCoordinator.recentEligibleWatchVideos(
                    storedCandidateVideosForTopic(topic.id),
                    store: self
                ).filter { candidate in
                    !isExcludedCreator(candidate.channelId)
                }
            )
        })

        let assigned = CandidateDiscoveryCoordinator.assignWatchVideosToTopics(perTopic)
        watchPoolByTopic = assigned
        rankedWatchPool = CandidateDiscoveryCoordinator.rerankWatchVideos(
            topics.flatMap { assigned[$0.id] ?? [] },
            store: self
        )
        scheduleWatchPoolVersionSignal()
        let duration = startedAt.duration(to: .now)
        AppLogger.discovery.info(
            "Rebuilt Watch pools for \(self.topics.count, privacy: .public) topics in \(duration.formatted(.units(allowed: [.milliseconds], width: .narrow)), privacy: .public); ranked candidates: \(self.rankedWatchPool.count, privacy: .public)"
        )
    }

    func reloadStoredCandidateCaches() {
        storedCandidateVideosByTopic = Dictionary(uniqueKeysWithValues: topics.map { topic in
            let candidates: [TopicCandidate]
            do {
                candidates = try store.candidatesForTopic(id: topic.id, limit: 36)
            } catch {
                AppLogger.discovery.error("Failed to load candidates for topic \(topic.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                candidates = []
            }
            return (topic.id, candidates.map(CandidateVideoViewModel.init(from:)))
        })
    }

    func reloadStoredCandidateCache(for topicId: Int64) {
        let candidates: [TopicCandidate]
        do {
            candidates = try store.candidatesForTopic(id: topicId, limit: 36)
        } catch {
            AppLogger.discovery.error("Failed to reload candidates for topic \(topicId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            candidates = []
        }
        storedCandidateVideosByTopic[topicId] = candidates.map(CandidateVideoViewModel.init(from:))
    }

    func updateViewportContext(topicId: Int64?, subtopicId: Int64?, creatorSectionId: String?) {
        viewportTopicId = topicId
        viewportSubtopicId = subtopicId
        viewportCreatorSectionId = creatorSectionId
    }

    func updateVisibleWatchTopics(_ topicIds: [Int64]) {
        guard visibleWatchTopicIds != topicIds else { return }
        visibleWatchTopicIds = topicIds
    }

    func prioritizedWatchRefreshTopicIDs(from topicIds: [Int64]) -> [Int64] {
        let remaining = Set(topicIds)
        var ordered: [Int64] = []

        func appendIfEligible(_ topicId: Int64?) {
            guard let topicId, remaining.contains(topicId), !ordered.contains(topicId) else { return }
            ordered.append(topicId)
        }

        appendIfEligible(selectedTopicId)
        visibleWatchTopicIds.forEach { appendIfEligible($0) }
        appendIfEligible(viewportTopicId)

        let fallbackOrder = topics.map(\.id).filter { remaining.contains($0) }
        fallbackOrder.forEach { appendIfEligible($0) }
        return ordered
    }

    func setWatchPresentationMode(_ mode: WatchPresentationMode) {
        guard watchPresentationMode != mode else { return }
        watchPresentationMode = mode
        AppLogger.discovery.info("Set watch presentation mode to \(mode.rawValue, privacy: .public)")
        watchPoolVersion &+= 1
    }

    func knownPlaylists() -> [PlaylistRecord] {
        do {
            return try store.knownPlaylists()
        } catch {
            AppLogger.app.error("Failed to load playlists: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func scheduleWatchPoolVersionSignal() {
        watchPoolVersionSignalTask?.cancel()
        watchPoolVersionSignalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.watchPoolVersion &+= 1
        }
    }

    // Candidate mutation and playlist operations are in OrganizerStore+VideoActions.swift

    private func rebuildVideoMaps() {
        var vMap: [String: VideoViewModel] = [:]
        var tMap: [String: Int64] = [:]
        var cCounts: [String: Int] = [:]
        var tChannels: [Int64: [ChannelRecord]] = [:]
        var knownChannels: [String: ChannelRecord] = [:]
        var tChannelCounts: [Int64: [String: Int]] = [:]
        var tChannelRecent: [Int64: Set<String>] = [:]
        var tSearchFields: [Int64: [String]] = [:]

        for topic in topics {
            var perTopicCounts: [String: Int] = [:]
            var perTopicRecent: Set<String> = []
            var searchFields = [topic.name]
            searchFields.append(contentsOf: topic.subtopics.map(\.name))

            for video in videosForTopicIncludingSubtopics(topic.id) {
                vMap[video.videoId] = video
                tMap[video.videoId] = topic.id
                searchFields.append(video.title)
                if let channelName = video.channelName, !channelName.isEmpty {
                    searchFields.append(channelName)
                }
                if let channel = video.channelName {
                    cCounts[channel, default: 0] += 1
                }
                if let cid = video.channelId {
                    perTopicCounts[cid, default: 0] += 1
                    if let pa = video.publishedAt, CreatorAnalytics.parseAge(pa) <= 7 {
                        perTopicRecent.insert(cid)
                    }
                }
            }

            tChannelCounts[topic.id] = perTopicCounts
            tChannelRecent[topic.id] = perTopicRecent
            tSearchFields[topic.id] = searchFields

            do {
                let channels = try store.channelsForTopicIncludingSubtopics(id: topic.id)
                tChannels[topic.id] = channels
                for channel in channels {
                    knownChannels[channel.channelId] = channel
                }
            } catch {
                AppLogger.app.error("Failed to load channels for topic \(topic.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        videoMap = vMap
        videoTopicMap = tMap
        channelCounts = cCounts
        topicChannels = tChannels
        knownChannelsById = knownChannels
        topicChannelCounts = tChannelCounts
        topicChannelRecent = tChannelRecent
        topicSearchFields = tSearchFields
    }

    func rebuildPlaylistMaps() {
        do {
            playlistsByVideoId = try store.allPlaylistsByVideo()
        } catch {
            AppLogger.app.error("Failed to rebuild playlist maps: \(error.localizedDescription, privacy: .public)")
            playlistsByVideoId = [:]
        }
    }

    /// Typeahead suggestions matching the current search text.
    func typeaheadSuggestions(limit: Int = 8) -> [TypeaheadSuggestion] {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return [] }
        // Don't show suggestions for exclude terms
        guard !text.hasPrefix("-") else { return [] }

        var results: [TypeaheadSuggestion] = []

        // Match topics and subtopics
        for topic in topics {
            if topic.name.localizedStandardContains(text) {
                results.append(TypeaheadSuggestion(
                    kind: .topic,
                    text: topic.name,
                    count: topic.videoCount,
                    topicId: topic.id
                ))
            }
            for sub in topic.subtopics where sub.name.localizedStandardContains(text) {
                results.append(TypeaheadSuggestion(
                    kind: .subtopic,
                    text: sub.name,
                    count: sub.videoCount,
                    topicId: sub.id,
                    parentName: topic.name
                ))
            }
        }

        // Match channels
        for (channel, count) in channelCounts where channel.localizedStandardContains(text) {
            results.append(TypeaheadSuggestion(
                kind: .channel,
                text: channel,
                count: count,
                topicId: nil
            ))
        }

        // Sort by count descending, take limit
        results.sort { $0.count > $1.count }
        return Array(results.prefix(limit))
    }

    // MARK: - Topic CRUD

    func renameTopic(_ topicId: Int64, to newName: String) {
        do {
            try store.renameTopic(id: topicId, to: newName)
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTopic(_ topicId: Int64) {
        do {
            try store.deleteTopic(id: topicId)
            if selectedTopicId == topicId { selectedTopicId = nil }
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func mergeTopics(sourceId: Int64, intoId: Int64) {
        do {
            try store.mergeTopic(sourceId: sourceId, intoId: intoId)
            if selectedTopicId == sourceId { selectedTopicId = intoId }
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveVideo(videoId: String, toTopicId: Int64) {
        do {
            try store.assignVideo(videoId: videoId, toTopic: toTopicId)
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveVideos(videoIds: Set<String>, toTopicId: Int64) {
        do {
            for vid in videoIds {
                try store.assignVideo(videoId: vid, toTopic: toTopicId)
            }
            selectedVideoId = nil
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - AI Operations

    func splitTopic(_ topicId: Int64, into count: Int = 3) async {
        guard let suggester else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let videos = try store.videosForTopic(id: topicId)
            let topic = topics.first { $0.id == topicId }
            let videoItems = videos.map { v in
                VideoItem(sourceIndex: v.sourceIndex, title: v.title, videoUrl: v.videoUrl,
                          videoId: v.videoId, channelName: v.channelName, metadataText: nil, unavailableKind: "none")
            }

            let subTopics = try await suggester.splitTopic(
                topicName: topic?.name ?? "",
                videos: videoItems,
                videoIndices: videos.map(\.sourceIndex),
                targetSubTopics: count
            )

            try store.deleteTopic(id: topicId)
            for sub in subTopics {
                let newId = try store.createTopic(name: sub.name)
                try store.assignVideos(indices: sub.videoIndices, toTopic: newId)
            }

            selectedTopicId = nil
            loadTopics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
