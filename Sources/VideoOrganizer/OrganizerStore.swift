import AppKit
import Foundation
import Observation
import TaggingKit

/// Main data store bridging TaggingKit's SQLite backend to SwiftUI's Observation.
@MainActor
@Observable
final class OrganizerStore {
    private(set) var topics: [TopicViewModel] = []
    private(set) var totalVideoCount: Int = 0
    private(set) var unassignedCount: Int = 0
    private(set) var isLoading = false
    var errorMessage: String?
    var alert: AppAlertState?
    var candidateRefreshToken = 0
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

    // Cached flat video map — rebuilt on loadTopics()
    var videoMap: [String: VideoViewModel] = [:]
    var videoTopicMap: [String: Int64] = [:]
    var syncTask: Task<Void, Never>?
    var browserSyncTask: Task<Void, Never>?
    var syncLoopTask: Task<Void, Never>?
    var browserStatusTask: Task<Void, Never>?
    var watchRefreshTask: Task<Void, Never>?
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
        excludedCreators = (try? store.excludedChannelsList()) ?? []
    }

    // MARK: - Loading

    func loadTopics() {
        do {
            let summaries = try store.listTopics()
            topics = summaries.map { summary in
                let subtopicSummaries = (try? store.subtopicsForTopic(id: summary.id)) ?? []
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

    func playlistsForVideo(_ videoId: String) -> [PlaylistRecord] {
        playlistsByVideoId[videoId] ?? []
    }

    func badgeTagForVideo(_ videoId: String, candidateState: String? = nil) -> String? {
        let playlists = playlistsByVideoId[videoId] ?? []
        if playlists.contains(where: { $0.playlistId == "WL" }) {
            return "Watch Later"
        }
        if candidateState == CandidateState.saved.rawValue {
            return "Saved"
        }
        return nil
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

    // Cached per-topic channel video counts: [topicId: [channelId: count]]
    var topicChannelCounts: [Int64: [String: Int]] = [:]

    // Cached per-topic channel recency: [topicId: Set<channelId>]
    var topicChannelRecent: [Int64: Set<String>] = [:]

    /// Returns channels with videos in the given topic (including subtopics), sorted by video count desc.
    func channelsForTopic(_ topicId: Int64) -> [ChannelRecord] {
        topicChannels[topicId] ?? []
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
        }
        candidateRefreshToken += 1
    }

    func updateViewportContext(topicId: Int64?, subtopicId: Int64?, creatorSectionId: String?) {
        viewportTopicId = topicId
        viewportSubtopicId = subtopicId
        viewportCreatorSectionId = creatorSectionId
    }

    func setWatchPresentationMode(_ mode: WatchPresentationMode) {
        guard watchPresentationMode != mode else { return }
        watchPresentationMode = mode
        AppLogger.discovery.info("Set watch presentation mode to \(mode.rawValue, privacy: .public)")
        candidateRefreshToken += 1
    }

    func knownPlaylists() -> [PlaylistRecord] {
        (try? store.knownPlaylists()) ?? []
    }

    func dismissCandidate(topicId: Int64, videoId: String) {
        setCandidateState(topicId: topicId, videoId: videoId, state: .dismissed)
    }

    func dismissCandidates(topicId: Int64, videoIds: [String]) {
        for videoId in videoIds {
            dismissCandidate(topicId: topicId, videoId: videoId)
        }
    }

    func excludeCreatorFromWatch(channelId: String?, channelName: String?, channelIconUrl: String? = nil) {
        guard let channelId, !channelId.isEmpty else {
            errorMessage = "This creator cannot be excluded because its channel ID is missing."
            return
        }

        let resolvedName = channelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedName, !resolvedName.isEmpty else {
            errorMessage = "This creator cannot be excluded because its channel name is missing."
            return
        }

        do {
            try store.excludeChannel(
                channelId: channelId,
                channelName: resolvedName,
                iconUrl: channelIconUrl,
                reason: "watch_feedback"
            )
            refreshExcludedCreators()

            if selectedChannelId == channelId {
                selectedChannelId = nil
                inspectedCreatorName = nil
            }

            selectedVideoId = nil
            hoveredVideoId = nil
            candidateRefreshToken += 1
            AppLogger.discovery.info("Excluded creator from watch: \(channelId, privacy: .public)")
            alert = AppAlertState(
                title: "Excluded Creator",
                message: "\(resolvedName) will no longer appear in Watch until you restore them in Settings."
            )
        } catch {
            AppLogger.discovery.error("Failed to exclude creator \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func restoreExcludedCreator(channelId: String) {
        do {
            try store.restoreExcludedChannel(channelId: channelId)
            refreshExcludedCreators()
            candidateRefreshToken += 1
            AppLogger.discovery.info("Restored excluded creator \(channelId, privacy: .public)")
        } catch {
            AppLogger.discovery.error("Failed to restore excluded creator \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func recordOpenedVideo(_ video: VideoGridItemModel) {
        do {
            let imported = try store.recordSeenVideo(
                videoId: video.id,
                title: video.title,
                channelName: video.channelName,
                rawURL: "https://www.youtube.com/watch?v=\(video.id)",
                source: .app,
                confidence: .probable
            )
            if imported > 0 {
                refreshSeenHistoryCount()
            }
        } catch {
            AppLogger.discovery.error("Failed to record app-seen event for \(video.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveCandidateToWatchLater(topicId: Int64, videoId: String) {
        let watchLater = PlaylistRecord(
            playlistId: "WL",
            title: "Watch Later",
            visibility: "Private",
            source: "queued",
            fetchedAt: ISO8601DateFormatter().string(from: Date())
        )
        saveCandidateToPlaylist(topicId: topicId, videoId: videoId, playlist: watchLater)
    }

    func saveCandidatesToWatchLater(topicId: Int64, videoIds: [String]) {
        for videoId in videoIds {
            saveCandidateToWatchLater(topicId: topicId, videoId: videoId)
        }
    }

    func saveCandidateToPlaylist(topicId: Int64, videoId: String, playlist: PlaylistRecord) {
        do {
            if playlistsByVideoId[videoId]?.contains(where: { $0.playlistId == playlist.playlistId }) == true {
                return
            }

            try store.upsertPlaylist(playlist)
            try store.addPlaylistMembership(PlaylistMembershipRecord(
                playlistId: playlist.playlistId,
                videoId: videoId,
                position: nil,
                verifiedAt: ISO8601DateFormatter().string(from: Date())
            ))
            try store.queueCommit(action: "add_to_playlist", videoId: videoId, playlist: playlist.playlistId)
            try store.setCandidateState(topicId: topicId, videoId: videoId, state: .saved)

            rebuildPlaylistMaps()
            candidateRefreshToken += 1
            AppLogger.discovery.info("Queued add_to_playlist for candidate \(videoId, privacy: .public) -> \(playlist.playlistId, privacy: .public)")
            if playlist.playlistId == "WL" {
                processPendingBrowserSync(reason: "save-candidate-watch-later")
            } else {
                processPendingSync(reason: "save-candidate")
            }
        } catch {
            AppLogger.discovery.error("Failed to queue add_to_playlist for candidate \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func saveCandidatesToPlaylist(topicId: Int64, videoIds: [String], playlist: PlaylistRecord) {
        for videoId in videoIds {
            saveCandidateToPlaylist(topicId: topicId, videoId: videoId, playlist: playlist)
        }
    }

    func saveVideosToWatchLater(videoIds: [String]) {
        let watchLater = PlaylistRecord(
            playlistId: "WL",
            title: "Watch Later",
            visibility: "Private",
            source: "queued",
            fetchedAt: ISO8601DateFormatter().string(from: Date())
        )
        saveVideosToPlaylist(videoIds: videoIds, playlist: watchLater)
    }

    func saveVideosToPlaylist(videoIds: [String], playlist: PlaylistRecord) {
        do {
            try store.upsertPlaylist(playlist)
            let now = ISO8601DateFormatter().string(from: Date())
            for videoId in videoIds {
                if playlistsByVideoId[videoId]?.contains(where: { $0.playlistId == playlist.playlistId }) == true {
                    continue
                }
                try store.addPlaylistMembership(PlaylistMembershipRecord(
                    playlistId: playlist.playlistId,
                    videoId: videoId,
                    position: nil,
                    verifiedAt: now
                ))
                try store.queueCommit(action: "add_to_playlist", videoId: videoId, playlist: playlist.playlistId)
            }

            rebuildPlaylistMaps()
            AppLogger.discovery.info("Queued add_to_playlist for \(videoIds.count, privacy: .public) saved videos -> \(playlist.playlistId, privacy: .public)")
            if playlist.playlistId == "WL" {
                processPendingBrowserSync(reason: "save-library-videos-watch-later")
            } else {
                processPendingSync(reason: "save-library-videos")
            }
        } catch {
            AppLogger.discovery.error("Failed to queue add_to_playlist for saved videos: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func removeVideosFromPlaylist(videoIds: [String], playlist: PlaylistRecord) {
        do {
            for videoId in videoIds {
                guard playlistsByVideoId[videoId]?.contains(where: { $0.playlistId == playlist.playlistId }) == true else {
                    continue
                }
                try store.removePlaylistMembership(playlistId: playlist.playlistId, videoId: videoId)
                try store.queueCommit(action: "remove_from_playlist", videoId: videoId, playlist: playlist.playlistId)
            }

            rebuildPlaylistMaps()
            AppLogger.discovery.info("Queued remove_from_playlist for \(videoIds.count, privacy: .public) saved videos <- \(playlist.playlistId, privacy: .public)")
            processPendingSync(reason: "remove-library-videos")
        } catch {
            AppLogger.discovery.error("Failed to queue remove_from_playlist for saved videos: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func markCandidateNotInterested(topicId: Int64, videoId: String) {
        do {
            try store.queueCommit(action: "not_interested", videoId: videoId, playlist: "__youtube__")
            try store.setCandidateState(topicId: topicId, videoId: videoId, state: .dismissed)
            candidateRefreshToken += 1
            AppLogger.discovery.info("Queued not_interested for candidate \(videoId, privacy: .public)")
            alert = AppAlertState(
                title: "Queued Not Interested",
                message: browserExecutorReady
                    ? "This candidate was hidden locally and queued for browser sync to YouTube."
                    : "This candidate was hidden locally. The direct YouTube action is queued, but the browser executor is not signed into YouTube yet."
            )
            if browserExecutorReady {
                processPendingBrowserSync(reason: "not-interested")
            }
        } catch {
            AppLogger.discovery.error("Failed to queue not_interested for candidate \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func markCandidatesNotInterested(topicId: Int64, videoIds: [String]) {
        for videoId in videoIds {
            markCandidateNotInterested(topicId: topicId, videoId: videoId)
        }
    }

    private func rebuildVideoMaps() {
        var vMap: [String: VideoViewModel] = [:]
        var tMap: [String: Int64] = [:]
        var cCounts: [String: Int] = [:]
        var tChannels: [Int64: [ChannelRecord]] = [:]
        var tChannelCounts: [Int64: [String: Int]] = [:]
        var tChannelRecent: [Int64: Set<String>] = [:]

        for topic in topics {
            var perTopicCounts: [String: Int] = [:]
            var perTopicRecent: Set<String> = []

            for video in videosForTopicIncludingSubtopics(topic.id) {
                vMap[video.videoId] = video
                tMap[video.videoId] = topic.id
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

            if let channels = try? store.channelsForTopicIncludingSubtopics(id: topic.id) {
                tChannels[topic.id] = channels
            }
        }
        videoMap = vMap
        videoTopicMap = tMap
        channelCounts = cCounts
        topicChannels = tChannels
        topicChannelCounts = tChannelCounts
        topicChannelRecent = tChannelRecent
    }

    private func rebuildPlaylistMaps() {
        playlistsByVideoId = (try? store.allPlaylistsByVideo()) ?? [:]
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

    // MARK: - Topic Operations

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

enum TopicDisplayMode: String, CaseIterable, Sendable {
    case saved
    case watchCandidates

    var label: String {
        switch self {
        case .saved:
            return "Saved"
        case .watchCandidates:
            return "Watch"
        }
    }
}

enum WatchPresentationMode: String, CaseIterable, Sendable {
    case byTopic
    case allTogether

    var label: String {
        switch self {
        case .byTopic:
            return "By Topic"
        case .allTogether:
            return "Show All"
        }
    }
}

struct CandidateProgressOverlayState: Equatable {
    let topicId: Int64
    let topicName: String
    let progress: Double
    let title: String
    let detail: String
}

// MARK: - View Models

struct TypeaheadSuggestion: Identifiable {
    enum Kind { case topic, subtopic, channel }
    let kind: Kind
    let text: String
    let count: Int
    let topicId: Int64?
    var parentName: String? = nil
    var id: String { "\(kind)-\(text)" }

    var icon: String {
        switch kind {
        case .topic: return TopicTheme.iconName(for: text)
        case .subtopic: return "arrow.turn.down.right"
        case .channel: return "person.circle.fill"
        }
    }

    var displayText: String {
        if let parent = parentName {
            return "\(text) — \(parent)"
        }
        return text
    }
}

struct TopicViewModel: Identifiable, Hashable {
    let id: Int64
    var name: String
    var videoCount: Int
    var parentId: Int64? = nil
    var subtopics: [TopicViewModel] = []

    static func == (lhs: TopicViewModel, rhs: TopicViewModel) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.videoCount == rhs.videoCount && lhs.subtopics.map(\.id) == rhs.subtopics.map(\.id)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct VideoViewModel: Identifiable, Hashable {
    let videoId: String
    let title: String
    let channelName: String?
    let videoUrl: String?
    let sourceIndex: Int
    let topicId: Int64?
    let viewCount: String?
    let publishedAt: String?
    let duration: String?
    let channelIconUrl: String?
    let channelId: String?

    var id: String { videoId }

    var youtubeUrl: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoId)")
    }

    var thumbnailUrl: URL? {
        guard let vid = videoUrl.flatMap({ URL(string: $0) })?.queryItems?["v"] ?? videoId.nilIfEmpty else {
            return nil
        }
        return URL(string: "https://i.ytimg.com/vi/\(vid)/mqdefault.jpg")
    }

    init(from stored: TaggingKit.StoredVideo) {
        self.videoId = stored.videoId
        self.title = stored.title ?? "Untitled"
        self.channelName = stored.channelName
        self.videoUrl = stored.videoUrl
        self.sourceIndex = stored.sourceIndex
        self.topicId = stored.topicId
        self.viewCount = stored.viewCount
        self.publishedAt = stored.publishedAt
        self.duration = stored.duration
        self.channelIconUrl = stored.channelIconUrl
        self.channelId = stored.channelId
    }

    init(videoId: String, title: String, channelName: String?, videoUrl: String?, sourceIndex: Int, topicId: Int64?, viewCount: String?, publishedAt: String?, duration: String?, channelIconUrl: String?, channelId: String? = nil) {
        self.videoId = videoId
        self.title = title
        self.channelName = channelName
        self.videoUrl = videoUrl
        self.sourceIndex = sourceIndex
        self.topicId = topicId
        self.viewCount = viewCount
        self.publishedAt = publishedAt
        self.duration = duration
        self.channelIconUrl = channelIconUrl
        self.channelId = channelId
    }

    init(from candidate: CandidateVideoViewModel) {
        self.videoId = candidate.videoId
        self.title = candidate.title
        self.channelName = candidate.channelName
        self.videoUrl = "https://www.youtube.com/watch?v=\(candidate.videoId)"
        self.sourceIndex = -1
        self.topicId = candidate.topicId
        self.viewCount = candidate.viewCount
        self.publishedAt = candidate.publishedAt
        self.duration = candidate.duration
        self.channelIconUrl = candidate.channelIconUrl
        self.channelId = candidate.channelId
    }
}

struct InspectedVideoViewModel {
    let video: VideoViewModel
    let playlists: [PlaylistRecord]
    let isWatchCandidate: Bool
    let seenSummary: SeenVideoSummary?
}

struct ChannelPresentation {
    let name: String?
    let channelUrl: String?
    let iconUrl: String?
    let iconData: Data?
}

struct CandidateVideoViewModel: Identifiable, Hashable {
    let topicId: Int64
    let videoId: String
    let title: String
    let channelId: String?
    let channelName: String?
    let viewCount: String?
    let publishedAt: String?
    let duration: String?
    let channelIconUrl: String?
    let score: Double
    let secondaryText: String?
    let state: String
    let isPlaceholder: Bool

    var id: String { "\(topicId)-\(videoId)" }

    var thumbnailUrl: URL? {
        guard !isPlaceholder else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
    }

    init(
        topicId: Int64,
        videoId: String,
        title: String,
        channelId: String?,
        channelName: String?,
        viewCount: String?,
        publishedAt: String?,
        duration: String?,
        channelIconUrl: String?,
        score: Double,
        secondaryText: String?,
        state: String,
        isPlaceholder: Bool
    ) {
        self.topicId = topicId
        self.videoId = videoId
        self.title = title
        self.channelId = channelId
        self.channelName = channelName
        self.viewCount = viewCount
        self.publishedAt = publishedAt
        self.duration = duration
        self.channelIconUrl = channelIconUrl
        self.score = score
        self.secondaryText = secondaryText
        self.state = state
        self.isPlaceholder = isPlaceholder
    }

    init(from stored: TopicCandidate) {
        self.init(
            topicId: stored.topicId,
            videoId: stored.videoId,
            title: stored.title,
            channelId: stored.channelId,
            channelName: stored.channelName,
            viewCount: stored.viewCount,
            publishedAt: stored.publishedAt,
            duration: stored.duration,
            channelIconUrl: stored.channelIconUrl,
            score: stored.score,
            secondaryText: stored.reason,
            state: stored.state,
            isPlaceholder: false
        )
    }

    static func placeholder(topicId: Int64, title: String, message: String) -> CandidateVideoViewModel {
        CandidateVideoViewModel(
            topicId: topicId,
            videoId: "candidate-placeholder-\(topicId)-\(title)",
            title: title,
            channelId: nil,
            channelName: nil,
            viewCount: nil,
            publishedAt: nil,
            duration: nil,
            channelIconUrl: nil,
            score: 0,
            secondaryText: message,
            state: CandidateState.candidate.rawValue,
            isPlaceholder: true
        )
    }
}

struct CreatorDetailViewModel {
    let channelName: String
    let channelIconUrl: String?
    let channelIconData: Data?
    let totalVideoCount: Int
    let totalViews: Int
    let newestAge: String?
    let oldestAge: String?
    let recentCount: Int           // videos from last 30 days
    let subscriberCount: Int?      // from channel record
    let totalUploads: Int?         // total videos on their channel
    let videosByTopic: [(topicName: String, videos: [VideoViewModel])]

    var formattedViews: String {
        if totalViews >= 1_000_000 {
            return String(format: "%.1fM views", Double(totalViews) / 1_000_000)
        } else if totalViews >= 1_000 {
            return String(format: "%.0fK views", Double(totalViews) / 1_000)
        }
        return "\(totalViews) views"
    }

    var formattedSubscribers: String? {
        guard let subs = subscriberCount else { return nil }
        if subs >= 1_000_000 {
            return String(format: "%.1fM subscribers", Double(subs) / 1_000_000)
        } else if subs >= 1_000 {
            return String(format: "%.0fK subscribers", Double(subs) / 1_000)
        }
        return "\(subs) subscribers"
    }

    var subscriberTier: String? {
        guard let subs = subscriberCount else { return nil }
        if subs >= 10_000_000 { return "mega creator" }
        if subs >= 1_000_000 { return "large creator" }
        if subs >= 100_000 { return "mid-tier creator" }
        if subs >= 10_000 { return "growing creator" }
        return "small creator"
    }

    var coverageText: String? {
        guard let total = totalUploads, total > 0 else { return nil }
        let pct = Int(Double(totalVideoCount) / Double(total) * 100)
        return "You've saved \(totalVideoCount) of \(total) videos (\(pct)%)"
    }

    var velocityText: String? {
        if recentCount == 0 { return nil }
        return "\(recentCount) new video\(recentCount == 1 ? "" : "s") in last 30 days"
    }
}

struct SubTopicSuggestion: Identifiable {
    let id = UUID()
    let name: String
    let estimatedCount: Int
    let description: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension URL {
    var queryItems: [String: String]? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [:]) { $0[$1.name] = $1.value }
    }
}
