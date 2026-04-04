import AppKit
import Foundation
import Observation
import TaggingKit
import UniformTypeIdentifiers

/// Main data store bridging TaggingKit's SQLite backend to SwiftUI's Observation.
@MainActor
@Observable
final class OrganizerStore {
    private(set) var topics: [TopicViewModel] = []
    private(set) var totalVideoCount: Int = 0
    private(set) var unassignedCount: Int = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var alert: AppAlertState?
    private(set) var candidateRefreshToken = 0
    private(set) var syncQueueSummary = SyncQueueSummary(queued: 0, retrying: 0, deferred: 0, inProgress: 0, browserDeferred: 0)
    private(set) var lastSyncErrorMessage: String?
    private(set) var lastSyncErrorIsBrowser = false
    private(set) var seenHistoryCount = 0
    private(set) var browserExecutorReady = false
    private(set) var browserExecutorStatusMessage = "Checking browser executor status…"

    // Selected state
    var selectedTopicId: Int64? {
        didSet {
            if oldValue != selectedTopicId {
                selectedChannelId = nil
                inspectedCreatorName = nil
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

    // Per-topic center-pane mode
    var topicDisplayModes: [Int64: TopicDisplayMode] = [:]
    private(set) var candidateErrors: [Int64: String] = [:]
    private(set) var candidateLoadingTopics: Set<Int64> = []
    private(set) var candidateProgressByTopic: [Int64: Double] = [:]
    private(set) var candidateCompletedChannelsByTopic: [Int64: Int] = [:]
    private(set) var candidateTotalChannelsByTopic: [Int64: Int] = [:]
    private(set) var candidateCurrentChannelNameByTopic: [Int64: String] = [:]

    // Cached flat video map — rebuilt on loadTopics()
    private var videoMap: [String: VideoViewModel] = [:]
    private var videoTopicMap: [String: Int64] = [:]
    private var syncTask: Task<Void, Never>?
    private var browserSyncTask: Task<Void, Never>?
    private var syncLoopTask: Task<Void, Never>?
    private var browserStatusTask: Task<Void, Never>?
    private var isUpdatingSelectionFromGrid = false

    private let store: TopicStore
    private let suggester: TopicSuggester?
    private let youtubeClient: YouTubeClient?

    init(dbPath: String, claudeClient: ClaudeClient? = nil) throws {
        self.store = try TopicStore(path: dbPath)
        self.suggester = claudeClient.map { TopicSuggester(client: $0) }
        self.youtubeClient = try? YouTubeClient()
        loadTopics()
        recoverInterruptedSyncActions(context: "startup")
        refreshSyncQueueSummary()
        refreshSeenHistoryCount()
        refreshBrowserExecutorStatus()
        processPendingSync(reason: "startup")
        processPendingBrowserSync(reason: "startup")
        startSyncLoop()
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
            let lhsDate = parseISO8601Date(lhs.publishedAt ?? "")
            let rhsDate = parseISO8601Date(rhs.publishedAt ?? "")
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
    private(set) var playlistsByVideoId: [String: [PlaylistRecord]] = [:]

    // Cached channels per topic — rebuilt on loadTopics()
    private(set) var topicChannels: [Int64: [ChannelRecord]] = [:]

    // Cached per-topic channel video counts: [topicId: [channelId: count]]
    private var topicChannelCounts: [Int64: [String: Int]] = [:]

    // Cached per-topic channel recency: [topicId: Set<channelId>]
    private var topicChannelRecent: [Int64: Set<String>] = [:]

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
                let lhsDate = parseISO8601Date(lhs.publishedAt ?? "")
                let rhsDate = parseISO8601Date(rhs.publishedAt ?? "")
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
        topicDisplayModes[targetTopicId] = .saved
        hoveredVideoId = nil
        selectedTopicId = targetTopicId
        selectedChannelId = resolvedChannel?.channelId ?? channelId
        inspectedCreatorName = resolvedChannel?.name ?? channelName
        selectedVideoId = targetVideos.first?.videoId

        AppLogger.discovery.info("Navigated to creator \(self.inspectedCreatorName ?? "", privacy: .public) in topic \(targetTopicId, privacy: .public)")
        return targetTopicId
    }

    func displayMode(for topicId: Int64) -> TopicDisplayMode {
        topicDisplayModes[topicId] ?? .saved
    }

    func setDisplayMode(_ mode: TopicDisplayMode, for topicId: Int64) {
        topicDisplayModes[topicId] = mode
        AppLogger.discovery.info("Set topic \(topicId, privacy: .public) display mode to \(mode.rawValue, privacy: .public)")
        if mode == .watchCandidates {
            selectedChannelId = nil
            selectedSubtopicId = nil
            selectedVideoId = nil
            if selectedTopicId != topicId {
                selectedTopicId = topicId
            }
        }
    }

    func activateDisplayMode(_ mode: TopicDisplayMode, for topicId: Int64) async {
        setDisplayMode(mode, for: topicId)
        guard mode == .watchCandidates else {
            candidateRefreshToken += 1
            return
        }
        if shouldUseCachedCandidates(for: topicId) {
            AppLogger.discovery.info("Using cached candidates for topic \(topicId, privacy: .public)")
            candidateRefreshToken += 1
            return
        }
        await ensureCandidates(for: topicId)
    }

    func candidateVideosForTopic(_ topicId: Int64) -> [CandidateVideoViewModel] {
        if candidateLoadingTopics.contains(topicId) {
            return [.placeholder(topicId: topicId, title: "Finding candidates…", message: "Checking cached creator archives and pulling only fresh uploads where needed.")]
        }

        if let error = candidateErrors[topicId] {
            return [.placeholder(topicId: topicId, title: "Could not load candidates", message: error)]
        }

        do {
            let storedCandidates = try store.candidatesForTopic(id: topicId, limit: 36)
            if storedCandidates.isEmpty {
                return [.placeholder(topicId: topicId, title: "No candidates yet", message: "No unseen candidates were found from this topic’s creators or adjacent saved-library channels.")]
            }
            return storedCandidates.map(CandidateVideoViewModel.init(from:))
        } catch {
            return [.placeholder(topicId: topicId, title: "Could not load candidates", message: error.localizedDescription)]
        }
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
        guard let topicId = selectedTopicId,
              displayMode(for: topicId) == .watchCandidates,
              candidateLoadingTopics.contains(topicId),
              let topic = topics.first(where: { $0.id == topicId })
        else {
            return nil
        }

        return CandidateProgressOverlayState(
            topicId: topicId,
            topicName: topic.name,
            progress: candidateProgress(for: topicId),
            title: candidateProgressTitle(for: topicId),
            detail: candidateProgressDetail(for: topicId)
        )
    }

    func setCandidateState(topicId: Int64, videoId: String, state: CandidateState) {
        do {
            try store.setCandidateState(topicId: topicId, videoId: videoId, state: state)
            AppLogger.discovery.info("Set candidate state for topic \(topicId, privacy: .public), video \(videoId, privacy: .public) to \(state.rawValue, privacy: .public)")
            candidateRefreshToken += 1
        } catch {
            AppLogger.discovery.error("Failed to set candidate state for topic \(topicId, privacy: .public), video \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
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

    func processPendingSync(reason: String = "manual") {
        guard syncTask == nil else {
            AppLogger.sync.debug("Skipping sync request for \(reason, privacy: .public); a sync task is already running")
            return
        }

        recoverInterruptedSyncActions(context: reason)

        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }

            do {
                self.refreshSyncQueueSummary()
                let pendingActions = try self.store.pendingSyncPlan(executor: .api)
                guard !pendingActions.isEmpty else {
                    AppLogger.sync.debug("No pending sync actions for \(reason, privacy: .public)")
                    return
                }

                AppLogger.sync.info("Syncing \(pendingActions.count, privacy: .public) pending YouTube actions for \(reason, privacy: .public)")
                try self.store.markInProgress(ids: pendingActions.map(\.id))
                let client = try YouTubeClient()
                let result = await YouTubeSyncService(client: client).execute(actions: pendingActions)
                try self.store.markSynced(ids: result.syncedActionIDs)
                try self.store.markDeferred(ids: result.deferredActionIDs, error: "Waiting for browser executor")
                try self.store.moveToExecutor(
                    ids: result.browserFallbackActionIDs,
                    executor: .browser,
                    state: .deferred,
                    error: "API quota exhausted. Waiting for browser executor fallback."
                )
                let retryDelay = self.retryDelay(for: result.failures)
                try self.store.markFailed(result.failures, retryAfter: retryDelay)

                if !result.syncedActionIDs.isEmpty {
                    AppLogger.sync.info("Synced \(result.syncedActionIDs.count, privacy: .public) YouTube actions")
                }

                if let firstFailure = result.failures.first {
                    AppLogger.sync.error("YouTube sync failure: \(firstFailure.message, privacy: .public)")
                    self.alert = AppAlertState(
                        title: "Could Not Save to YouTube",
                        message: firstFailure.message
                    )
                    self.lastSyncErrorMessage = firstFailure.message
                    self.lastSyncErrorIsBrowser = false
                }

                if !result.deferredActionIDs.isEmpty {
                    AppLogger.sync.info("Deferred \(result.deferredActionIDs.count, privacy: .public) browser-only sync actions")
                }

                if !result.browserFallbackActionIDs.isEmpty {
                    AppLogger.sync.info("Moved \(result.browserFallbackActionIDs.count, privacy: .public) actions to browser fallback after API quota exhaustion")
                    self.alert = AppAlertState(
                        title: "Using Browser Fallback",
                        message: "YouTube API quota is exhausted, so queued save actions have been moved to the browser executor path. They will stay queued until the Playwright worker is attached."
                    )
                    self.processPendingBrowserSync(reason: "quota-fallback")
                }
                self.refreshSyncQueueSummary()
            } catch {
                AppLogger.sync.error("Pending sync run failed: \(error.localizedDescription, privacy: .public)")
                self.alert = AppAlertState(
                    title: "Could Not Save to YouTube",
                    message: error.localizedDescription
                )
                self.lastSyncErrorMessage = error.localizedDescription
                self.lastSyncErrorIsBrowser = false
                self.refreshSyncQueueSummary()
            }
        }
    }

    func processPendingBrowserSync(reason: String = "manual") {
        guard browserSyncTask == nil else {
            AppLogger.sync.debug("Skipping browser sync request for \(reason, privacy: .public); a browser sync task is already running")
            return
        }

        recoverInterruptedSyncActions(context: reason)

        browserSyncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.browserSyncTask = nil }

            do {
                self.refreshSyncQueueSummary()
                let pendingActions = try self.store.pendingSyncPlan(executor: .browser)
                guard !pendingActions.isEmpty else {
                    AppLogger.sync.debug("No pending browser sync actions for \(reason, privacy: .public)")
                    return
                }

                AppLogger.sync.info("Syncing \(pendingActions.count, privacy: .public) pending browser actions for \(reason, privacy: .public)")
                try self.store.markInProgress(ids: pendingActions.map(\.id))
                let repoRoot = self.resolveRepoRoot()
                let result = try await BrowserSyncService(repoRoot: repoRoot).execute(actions: pendingActions)
                try self.store.markSynced(ids: result.syncedActionIDs)
                let retryDelay = self.retryDelay(for: result.failures)
                try self.store.markFailed(result.failures, retryAfter: retryDelay)

                if !result.syncedActionIDs.isEmpty {
                    AppLogger.sync.info("Synced \(result.syncedActionIDs.count, privacy: .public) browser actions")
                }

                if let firstFailure = result.failures.first {
                    AppLogger.sync.error("Browser sync failure: \(firstFailure.message, privacy: .public)")
                    self.alert = AppAlertState(
                        title: "Could Not Sync Browser Actions",
                        message: firstFailure.message
                    )
                    self.lastSyncErrorMessage = firstFailure.message
                    self.lastSyncErrorIsBrowser = true
                }
                self.refreshSyncQueueSummary()
            } catch {
                AppLogger.sync.error("Pending browser sync run failed: \(error.localizedDescription, privacy: .public)")
                self.alert = AppAlertState(
                    title: "Could Not Sync Browser Actions",
                    message: error.localizedDescription
                )
                self.lastSyncErrorMessage = error.localizedDescription
                self.lastSyncErrorIsBrowser = true
                self.refreshSyncQueueSummary()
            }
        }
    }

    func openBrowserSyncLogin() {
        Task {
            do {
                try await BrowserSyncService(repoRoot: resolveRepoRoot()).openLoginSetup()
                bringBrowserSyncWindowToFront()
                browserExecutorReady = false
                browserExecutorStatusMessage = "Browser sign-in window opened. Sign in to YouTube there if needed, then return here and click Refresh sync status."
                alert = AppAlertState(
                    title: "Browser Sign-In Opened",
                    message: "A dedicated Chrome profile window was opened for browser fallback actions. Sign in to YouTube there if needed, then refresh sync status here."
                )
            } catch {
                alert = AppAlertState(
                    title: "Could Not Open Browser Sign-In",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func bringBrowserSyncWindowToFront() {
        if let runningChrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
            runningChrome.activate(options: [.activateAllWindows])
            return
        }

        if let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: chromeURL, configuration: configuration)
        }
    }

    func refreshSyncQueueSummary() {
        syncQueueSummary = (try? store.syncQueueSummary()) ?? SyncQueueSummary(queued: 0, retrying: 0, deferred: 0, inProgress: 0, browserDeferred: 0)
    }

    func refreshBrowserExecutorStatus() {
        browserStatusTask?.cancel()
        browserExecutorStatusMessage = "Checking browser executor status…"
        let repoRoot = resolveRepoRoot()
        browserStatusTask = Task.detached(priority: .userInitiated) {
            let resolvedStatus: BrowserExecutorStatus
            do {
                resolvedStatus = try await withThrowingTaskGroup(of: BrowserExecutorStatus.self) { group in
                    group.addTask {
                        try await BrowserSyncService(repoRoot: repoRoot).status()
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        return BrowserExecutorStatus(
                            ready: false,
                            message: "Browser status check timed out. If the sign-in window is open, finish there and then refresh sync status."
                        )
                    }

                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                }
            } catch {
                resolvedStatus = BrowserExecutorStatus(
                    ready: false,
                    message: error.localizedDescription
                )
            }

            if Task.isCancelled { return }
            await MainActor.run {
                self.browserExecutorReady = resolvedStatus.ready
                self.browserExecutorStatusMessage = resolvedStatus.message
                self.browserStatusTask = nil
            }
        }
    }

    func openBrowserSyncArtifactsFolder() {
        let artifactsURL = resolveRepoRoot().appendingPathComponent("output/playwright/browser-sync")
        NSWorkspace.shared.open(artifactsURL)
    }

    func importSeenHistoryFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Seen History"
        panel.message = "Choose a Google Takeout or My Activity export file."
        panel.allowedContentTypes = [.json, .html, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let records = try SeenHistoryImporter.loadRecords(from: url)
            let imported = try store.importSeenVideoRecords(records)
            refreshSeenHistoryCount()
            candidateRefreshToken += 1
            AppLogger.discovery.info("Imported \(imported, privacy: .public) seen-history records from \(url.lastPathComponent, privacy: .public)")
            alert = AppAlertState(
                title: "Seen History Imported",
                message: "Parsed \(records.count) history records and imported \(imported) new entries from \(url.lastPathComponent)."
            )
        } catch {
            AppLogger.discovery.error("Failed to import seen history from \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            alert = AppAlertState(
                title: "Could Not Import Seen History",
                message: error.localizedDescription
            )
        }
    }

    private func startSyncLoop() {
        guard syncLoopTask == nil else { return }
        syncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await MainActor.run {
                    self.processPendingSync(reason: "timer")
                    self.processPendingBrowserSync(reason: "timer")
                }
            }
        }
    }

    private func retryDelay(for failures: [SyncFailureRecord]) -> TimeInterval? {
        guard let first = failures.first else { return nil }
        let message = first.message.lowercased()
        if message.contains("quota") || message.contains("daily limit") || message.contains("exceeded") {
            return 60 * 60
        }
        if message.contains("write access is not available") || message.contains("reconnect youtube") {
            return 15 * 60
        }
        return 5 * 60
    }

    private func recoverInterruptedSyncActions(context: String) {
        do {
            let recovered = try store.recoverStaleInProgressCommits()
            guard recovered > 0 else { return }
            AppLogger.sync.info("Recovered \(recovered, privacy: .public) interrupted sync actions before \(context, privacy: .public)")
            refreshSyncQueueSummary()
        } catch {
            AppLogger.sync.error("Failed to recover interrupted sync actions before \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshSeenHistoryCount() {
        seenHistoryCount = (try? store.seenVideoCount()) ?? 0
    }

    private func resolveRepoRoot() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("scripts/youtube_browser_sync.mjs").path) {
            return cwd
        }

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let root = bundleURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/youtube_browser_sync.mjs").path) {
                return root
            }
        }

        return cwd
    }

    /// Get all videos by a creator name, grouped by topic.
    func creatorDetail(channelName: String) -> CreatorDetailViewModel {
        var videosByTopic: [(topicName: String, videos: [VideoViewModel])] = []
        var totalViews = 0
        var oldestDays = 0
        var newestDays = Int.max
        var recentCount = 0  // videos from last 30 days

        for topic in topics {
            let videos = videosForTopicIncludingSubtopics(topic.id).filter { $0.channelName == channelName }
            if !videos.isEmpty {
                videosByTopic.append((topicName: topic.name, videos: videos))
                for v in videos {
                    if let vc = v.viewCount { totalViews += parseViewCount(vc) }
                    if let pa = v.publishedAt {
                        let days = parseAge(pa)
                        oldestDays = max(oldestDays, days)
                        newestDays = min(newestDays, days)
                        if days <= 30 { recentCount += 1 }
                    }
                }
            }
        }

        let channelIconUrl = videosByTopic.flatMap(\.videos).first(where: { $0.channelIconUrl != nil })?.channelIconUrl
        let totalCount = videosByTopic.reduce(0) { $0 + $1.videos.count }

        // Look up channel record for subscriber count and total uploads
        let channelId = videosByTopic.flatMap(\.videos).first(where: { $0.channelId != nil })?.channelId
        let channelRecord = channelId.flatMap { cId in topicChannels.values.flatMap { $0 }.first(where: { $0.channelId == cId }) }

        let subscriberCount = channelRecord?.subscriberCount.flatMap { Int($0) }
        let totalUploads = channelRecord?.videoCountTotal

        return CreatorDetailViewModel(
            channelName: channelName,
            channelIconUrl: channelIconUrl,
            channelIconData: channelRecord?.iconData,
            totalVideoCount: totalCount,
            totalViews: totalViews,
            newestAge: newestDays == Int.max ? nil : formatAge(newestDays),
            oldestAge: oldestDays == 0 ? nil : formatAge(oldestDays),
            recentCount: recentCount,
            subscriberCount: subscriberCount,
            totalUploads: totalUploads,
            videosByTopic: videosByTopic
        )
    }

    private func parseViewCount(_ str: String) -> Int {
        let cleaned = str.replacingOccurrences(of: " views", with: "")
        if cleaned.hasSuffix("M") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000_000)
        } else if cleaned.hasSuffix("K") {
            return Int((Double(cleaned.dropLast()) ?? 0) * 1_000)
        }
        return Int(cleaned) ?? 0
    }

    private func parseAge(_ str: String) -> Int {
        if str == "today" { return 0 }
        let parts = str.split(separator: " ")
        guard parts.count >= 2, let num = Int(parts[0]) else { return Int.max }
        let unit = String(parts[1])
        if unit.hasPrefix("day") { return num }
        if unit.hasPrefix("month") { return num * 30 }
        if unit.hasPrefix("year") { return num * 365 }
        return Int.max
    }

    private func formatAge(_ days: Int) -> String {
        if days == 0 { return "today" }
        if days == 1 { return "1 day ago" }
        if days < 30 { return "\(days) days ago" }
        let months = days / 30
        if months == 1 { return "1 month ago" }
        if months < 12 { return "\(months) months ago" }
        let years = months / 12
        if years == 1 { return "1 year ago" }
        return "\(years) years ago"
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
                    if let pa = video.publishedAt, parseAge(pa) <= 7 {
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

    private func ensureCandidates(for topicId: Int64) async {
        guard !candidateLoadingTopics.contains(topicId) else { return }
        candidateLoadingTopics.insert(topicId)
        candidateProgressByTopic[topicId] = 0
        candidateCompletedChannelsByTopic[topicId] = 0
        candidateTotalChannelsByTopic[topicId] = 0
        candidateCurrentChannelNameByTopic[topicId] = nil
        candidateErrors[topicId] = nil
        candidateRefreshToken += 1
        AppLogger.discovery.info("Starting candidate refresh for topic \(topicId, privacy: .public)")
        defer {
            candidateLoadingTopics.remove(topicId)
            candidateProgressByTopic[topicId] = nil
            candidateCompletedChannelsByTopic[topicId] = nil
            candidateTotalChannelsByTopic[topicId] = nil
            candidateCurrentChannelNameByTopic[topicId] = nil
            candidateRefreshToken += 1
            AppLogger.discovery.info("Finished candidate refresh for topic \(topicId, privacy: .public)")
        }

        do {
            let channelPlans = candidateChannelPlans(for: topicId)
            AppLogger.discovery.debug("Candidate refresh topic \(topicId, privacy: .public) using \(channelPlans.count, privacy: .public) discovery channels")
            guard !channelPlans.isEmpty else {
                try store.replaceCandidates(forTopic: topicId, candidates: [], sources: [])
                AppLogger.discovery.info("Topic \(topicId, privacy: .public) has no associated discovery channels; cleared candidates")
                return
            }

            let existingVideoIds = Set(videosForTopicIncludingSubtopics(topicId).map(\.videoId))
            var aggregate: [String: AggregatedCandidate] = [:]
            let totalChannels = max(channelPlans.count, 1)
            var completedChannels = 0
            candidateTotalChannelsByTopic[topicId] = channelPlans.count
            candidateCompletedChannelsByTopic[topicId] = 0
            candidateCurrentChannelNameByTopic[topicId] = channelPlans.first?.channel.name
            candidateRefreshToken += 1

            for plan in channelPlans {
                let channel = plan.channel
                candidateCurrentChannelNameByTopic[topicId] = channel.name
                candidateRefreshToken += 1
                let archived = try await refreshChannelArchiveIfNeeded(channel: channel, youtubeClient: youtubeClient)
                AppLogger.discovery.debug("Using \(archived.count, privacy: .public) archived upload videos for channel \(channel.channelId, privacy: .public)")

                for video in archived {
                    accumulateCandidate(
                        video: video,
                        topicId: topicId,
                        channel: channel,
                        sourceKind: plan.sourceKind,
                        sourceRef: plan.sourceRef,
                        creatorAffinity: plan.creatorAffinity,
                        reasonHint: plan.reasonHint,
                        existingVideoIds: existingVideoIds,
                        aggregate: &aggregate
                    )
                }

                completedChannels += 1
                candidateCompletedChannelsByTopic[topicId] = completedChannels
                candidateProgressByTopic[topicId] = Double(completedChannels) / Double(totalChannels)
                candidateRefreshToken += 1
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
            AppLogger.discovery.info("Stored \(candidates.count, privacy: .public) candidates and \(sources.count, privacy: .public) sources for topic \(topicId, privacy: .public)")
        } catch {
            candidateErrors[topicId] = friendlyCandidateErrorMessage(for: error)
            presentQuotaAlertIfNeeded(for: error)
            AppLogger.discovery.error("Candidate refresh failed for topic \(topicId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func accumulateCandidate(
        video: ArchivedChannelVideo,
        topicId: Int64,
        channel: ChannelRecord,
        sourceKind: String,
        sourceRef: String,
        creatorAffinity: Int,
        reasonHint: String?,
        existingVideoIds: Set<String>,
        aggregate: inout [String: AggregatedCandidate]
    ) {
        guard !existingVideoIds.contains(video.videoId) else { return }

        let publishedDays = parseAge(video.publishedAt ?? "")
        let recencyBonus: Int
        if sourceKind == "channel_archive_recent" {
            if publishedDays <= 7 {
                recencyBonus = 30
            } else if publishedDays <= 30 {
                recencyBonus = 24
            } else if publishedDays <= 90 {
                recencyBonus = 16
            } else if publishedDays <= 180 {
                recencyBonus = 8
            } else {
                recencyBonus = 2
            }
        } else {
            recencyBonus = 0
        }

        let archivalBonus = 0
        let creatorBonus = min(creatorAffinity, 16)
        let qualityBonus = min(parseViewCount(video.viewCount ?? "") / 75_000, 6)
        let sourceScore: (freshness: Int, creatorWeight: Int, bonus: Int)
        let reason: String
        switch sourceKind {
        case "channel_archive_recent":
            sourceScore = (freshness: 10, creatorWeight: 3, bonus: 0)
            reason = "Fresh upload from a creator already in this topic"
        case "playlist_adjacent_recent":
            sourceScore = (freshness: 6, creatorWeight: 2, bonus: 8)
            if let reasonHint, !reasonHint.isEmpty {
                reason = "Fresh upload from a creator adjacent to this topic via \(reasonHint)"
            } else {
                reason = "Fresh upload from a creator adjacent to this topic in your saved library"
            }
        default:
            sourceScore = (freshness: 4, creatorWeight: 2, bonus: 0)
            reason = "Recent candidate from a related creator"
        }
        let score = Double(
            sourceScore.freshness +
            recencyBonus * 4 +
            creatorBonus * sourceScore.creatorWeight +
            archivalBonus * 2 +
            qualityBonus +
            sourceScore.bonus
        )

        if var existing = aggregate[video.videoId] {
            existing.score += score + 3
            let nowHasCoreSource = existing.sources.contains(where: { $0.kind == "channel_archive_recent" }) || sourceKind == "channel_archive_recent"
            let nowHasAdjacentSource = existing.sources.contains(where: { $0.kind == "playlist_adjacent_recent" }) || sourceKind == "playlist_adjacent_recent"
            if nowHasCoreSource && nowHasAdjacentSource {
                existing.reason = "Fresh upload connected to this topic and your saved playlists"
            } else if sourceKind == "playlist_adjacent_recent" {
                existing.reason = reason
            } else if sourceKind == "channel_archive_recent" {
                existing.reason = "Fresh upload from a creator already in this topic"
            }
            existing.sources.insert(CandidateSource(kind: sourceKind, ref: sourceRef))
            aggregate[video.videoId] = existing
        } else {
            aggregate[video.videoId] = AggregatedCandidate(
                videoId: video.videoId,
                title: video.title,
                channelId: channel.channelId,
                channelName: video.channelName ?? channel.name,
                viewCount: video.viewCount,
                publishedAt: video.publishedAt,
                duration: video.duration,
                channelIconUrl: video.channelIconUrl ?? channel.iconUrl,
                score: score,
                reason: reason,
                sources: [CandidateSource(kind: sourceKind, ref: sourceRef)]
            )
        }
    }

    private func refreshChannelArchiveIfNeeded(channel: ChannelRecord, youtubeClient: YouTubeClient?) async throws -> [ArchivedChannelVideo] {
        let existingArchive = try store.archivedVideosForChannels([channel.channelId], perChannelLimit: 24)
        let knownVideoIDs = try store.archivedVideoIDsForChannel(channel.channelId)
        let lastScannedAt = try store.channelDiscoveryLastScannedAt(channelId: channel.channelId)
        guard shouldRefreshArchive(lastScannedAt: lastScannedAt) else {
            return existingArchive
        }

        AppLogger.discovery.debug("Refreshing archive for channel \(channel.channelId, privacy: .public)")

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
            let recent = incremental.videos
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
            try store.upsertChannelDiscoveryArchive(channelId: channel.channelId, videos: archived, scannedAt: scannedAt)
            AppLogger.discovery.info(
                "Channel \(channel.channelId, privacy: .public) archive refresh via API: \(recent.count, privacy: .public) new uploads, \(incremental.pagesFetched, privacy: .public) page(s) fetched, hit known video: \(incremental.hitKnownVideo, privacy: .public)"
            )
            return try store.archivedVideosForChannels([channel.channelId], perChannelLimit: 24)
        } catch {
            if let youtubeError = error as? YouTubeError, youtubeError.isQuotaExceeded {
                AppLogger.discovery.info("YouTube API quota exhausted for channel \(channel.channelId, privacy: .public); using public discovery fallback")
            } else {
                AppLogger.discovery.info("Primary channel discovery failed for \(channel.channelId, privacy: .public); trying public fallback: \(error.localizedDescription, privacy: .public)")
            }

            do {
                let repoRoot = resolveRepoRoot()
                let recent = try await DiscoveryFallbackService(repoRoot: repoRoot)
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
                try store.upsertChannelDiscoveryArchive(channelId: channel.channelId, videos: archived, scannedAt: scannedAt)
                AppLogger.discovery.info(
                    "Channel \(channel.channelId, privacy: .public) archive refresh via fallback: \(recent.count, privacy: .public) new uploads"
                )
                return try store.archivedVideosForChannels([channel.channelId], perChannelLimit: 24)
            } catch {
                if !existingArchive.isEmpty {
                    AppLogger.discovery.error("Fallback discovery failed for \(channel.channelId, privacy: .public); using stale archive: \(error.localizedDescription, privacy: .public)")
                    return existingArchive
                }
                throw error
            }
        }
    }
}

private extension OrganizerStore {
    func candidateCreatorScanLimit(for topicId: Int64) -> Int {
        let count = channelsForTopic(topicId).count
        switch count {
        case 0...6:
            return 6
        case 7...12:
            return 10
        case 13...24:
            return 12
        default:
            return 16
        }
    }

    func candidateExploratoryScanLimit(for topicId: Int64) -> Int {
        let count = channelsForTopic(topicId).count
        switch count {
        case 0...6:
            return 2
        case 7...12:
            return 3
        case 13...24:
            return 4
        default:
            return 6
        }
    }

    func candidateChannelPlans(for topicId: Int64) -> [CandidateChannelPlan] {
        let coreChannels = Array(channelsForTopic(topicId).prefix(candidateCreatorScanLimit(for: topicId)))
        var plans = coreChannels.map {
            CandidateChannelPlan(
                channel: $0,
                sourceKind: "channel_archive_recent",
                sourceRef: $0.channelId,
                creatorAffinity: videoCountForChannel($0.channelId, inTopic: topicId),
                reasonHint: nil
            )
        }

        let excluded = Set(coreChannels.map(\.channelId))
        let exploratory = exploratoryChannelsForTopic(
            topicId,
            excluding: excluded,
            limit: candidateExploratoryScanLimit(for: topicId)
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

    func exploratoryChannelsForTopic(_ topicId: Int64, excluding excludedChannelIds: Set<String>, limit: Int) -> [ExploratoryChannelCandidate] {
        guard limit > 0 else { return [] }

        let topicVideos = videosForTopicIncludingSubtopics(topicId)
        let topicVideoIds = Set(topicVideos.map(\.videoId))
        guard !topicVideos.isEmpty else { return [] }

        var playlistWeights: [String: Double] = [:]
        var playlistTitles: [String: String] = [:]
        for video in topicVideos {
            for playlist in playlistsByVideoId[video.videoId] ?? [] {
                guard isUsefulDiscoveryPlaylist(playlist) else { continue }
                let videoCount = max(playlist.videoCount ?? 0, 1)
                let weight = 1.0 / max(log10(Double(max(videoCount, 10))), 1.0)
                playlistWeights[playlist.playlistId, default: 0] += weight
                playlistTitles[playlist.playlistId] = playlist.title
            }
        }

        guard !playlistWeights.isEmpty else { return [] }

        var overlapByChannel: [String: (score: Double, bestPlaylistId: String, sampleVideo: VideoViewModel)] = [:]
        for (videoId, playlists) in playlistsByVideoId {
            guard !topicVideoIds.contains(videoId),
                  let video = videoMap[videoId],
                  let channelId = video.channelId,
                  !channelId.isEmpty,
                  !excludedChannelIds.contains(channelId)
            else {
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

            let current = overlapByChannel[channelId]
            if let current {
                overlapByChannel[channelId] = (
                    current.score + overlapScore,
                    current.bestPlaylistId,
                    current.sampleVideo
                )
            } else {
                overlapByChannel[channelId] = (overlapScore, bestPlaylist.id, video)
            }
        }

        return overlapByChannel
            .sorted { lhs, rhs in
                if lhs.value.score == rhs.value.score {
                    let lhsDate = parseISO8601Date(lhs.value.sampleVideo.publishedAt ?? "")
                    let rhsDate = parseISO8601Date(rhs.value.sampleVideo.publishedAt ?? "")
                    switch (lhsDate, rhsDate) {
                    case let (l?, r?) where l != r:
                        return l > r
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
                guard let channel = resolveChannelRecord(
                    channelId: channelId,
                    fallbackName: entry.sampleVideo.channelName,
                    fallbackIconURL: entry.sampleVideo.channelIconUrl
                ) else {
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

    func isUsefulDiscoveryPlaylist(_ playlist: PlaylistRecord) -> Bool {
        if playlist.playlistId == "WL" {
            return false
        }

        let normalized = playlist.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "old watch" || normalized == "watch later" {
            return false
        }

        if let videoCount = playlist.videoCount, videoCount > 800 {
            return false
        }

        return true
    }

    func resolveChannelRecord(channelId: String, fallbackName: String?, fallbackIconURL: String?) -> ChannelRecord? {
        if let existing = topicChannels.values
            .flatMap({ $0 })
            .first(where: { $0.channelId == channelId }) {
            return existing
        }

        if let fromStore = try? store.channelById(channelId) {
            return fromStore
        }

        guard let fallbackName, !fallbackName.isEmpty else {
            return nil
        }

        return ChannelRecord(
            channelId: channelId,
            name: fallbackName,
            channelUrl: "https://www.youtube.com/channel/\(channelId)",
            iconUrl: fallbackIconURL
        )
    }

    func shouldUseCachedCandidates(for topicId: Int64) -> Bool {
        guard let latest = try? store.latestCandidateDiscoveredAt(topicId: topicId),
              let latestDate = ISO8601DateFormatter().date(from: latest)
        else {
            return false
        }

        return Date().timeIntervalSince(latestDate) < (6 * 60 * 60)
    }

    func shouldRefreshArchive(lastScannedAt: String?) -> Bool {
        guard let lastScannedAt else { return true }
        guard let scannedDate = parseISO8601Date(lastScannedAt) else { return true }
        return Date().timeIntervalSince(scannedDate) >= (12 * 60 * 60)
    }

    func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    func friendlyCandidateErrorMessage(for error: Error) -> String {
        if let youtubeError = error as? YouTubeError,
           youtubeError.isQuotaExceeded {
            return "YouTube API quota is exhausted for today. Existing saved videos still work, and candidate discovery will work again after quota resets at midnight Pacific."
        }
        return error.localizedDescription
    }

    func presentQuotaAlertIfNeeded(for error: Error) {
        guard let youtubeError = error as? YouTubeError,
              youtubeError.isQuotaExceeded
        else {
            return
        }

        alert = AppAlertState(
            title: "YouTube Quota Exhausted",
            message: "The app has used today’s YouTube Data API quota for discovery. Candidate generation is paused until quota resets at midnight Pacific. Saved videos, playlists, and existing cached candidates are still available."
        )
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
