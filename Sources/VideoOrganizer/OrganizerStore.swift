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
    internal(set) var isLoading = false
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
    var favoriteCreators: [FavoriteChannelRecord] = []
    /// Push path for the detail-column NavigationStack. Empty when the topic grid is the
    /// visible content; non-empty when a creator (or future destination) detail page is
    /// pushed on top of the grid. Mutated by `openCreatorDetail(channelId:)` and the
    /// NavigationStack back button.
    var detailPath: [DetailRoute] = []
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

    // Page-level center-pane mode (persisted across launches)
    var pageDisplayMode: TopicDisplayMode = {
        TopicDisplayMode(rawValue: UserDefaults.standard.string(forKey: "pageDisplayMode") ?? "") ?? .saved
    }() {
        didSet { UserDefaults.standard.set(pageDisplayMode.rawValue, forKey: "pageDisplayMode") }
    }
    var watchPresentationMode: WatchPresentationMode = {
        WatchPresentationMode(rawValue: UserDefaults.standard.string(forKey: "watchPresentationMode") ?? "") ?? .byTopic
    }() {
        didSet { UserDefaults.standard.set(watchPresentationMode.rawValue, forKey: "watchPresentationMode") }
    }
    var candidateErrors: [Int64: String] = [:]
    var candidateLoadingTopics: Set<Int64> = []
    var candidateProgressByTopic: [Int64: Double] = [:]
    var candidateCompletedChannelsByTopic: [Int64: Int] = [:]
    var candidateTotalChannelsByTopic: [Int64: Int] = [:]
    var candidateCurrentChannelNameByTopic: [Int64: String] = [:]
    var watchRefreshCompletedTopics = 0
    var watchRefreshTotalTopics = 0
    var watchRefreshCurrentTopicName: String?
    var youtubeQuotaExhausted = false
    var youtubeQuotaSnapshot: YouTubeQuotaSnapshot?
    /// Phase 3: aggregated scrape health from the last hour of discovery
    /// events. Surfaced as a status pill in the topic sidebar footer and as a
    /// sticky banner in the main view when state == .blocked. Refreshed after
    /// every scrape attempt by `refreshScrapeHealth` and on a periodic timer.
    var scrapeHealth: ScrapeHealthSnapshot?
    var pendingAPIFallbackApproval: APIFallbackApprovalRequest?

    /// User opt-in for the very expensive search.list API fallback (100 units/call).
    /// Default off; only the scrape path is allowed unless the user explicitly enables this.
    var apiSearchFallbackEnabled: Bool = UserDefaults.standard.bool(forKey: "apiSearchFallbackEnabled") {
        didSet { UserDefaults.standard.set(apiSearchFallbackEnabled, forKey: "apiSearchFallbackEnabled") }
    }

    /// User opt-in for the Phase 2 Claude theme classifier on the creator detail page.
    /// Default ON — costs ~$0.001-0.005 per creator on first visit, then cached forever.
    /// Existing installs that explicitly set it to false keep that choice; only fresh
    /// installs (no UserDefaults entry yet) get the new default. Mirrors the apiSearchFallbackEnabled
    /// gate but flipped because the user wants tags to appear automatically.
    var claudeThemeClassificationEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "claudeThemeClassificationEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "claudeThemeClassificationEnabled")
    }() {
        didSet { UserDefaults.standard.set(claudeThemeClassificationEnabled, forKey: "claudeThemeClassificationEnabled") }
    }

    /// Maximum estimated YouTube units a single Watch refresh pass is allowed to spend on API
    /// fallbacks. Acts as a hard ceiling on top of any user approvals.
    var apiFallbackPassBudgetUnits: Int = {
        let stored = UserDefaults.standard.integer(forKey: "apiFallbackPassBudgetUnits")
        return stored > 0 ? stored : 1_000
    }() {
        didSet { UserDefaults.standard.set(apiFallbackPassBudgetUnits, forKey: "apiFallbackPassBudgetUnits") }
    }

    /// Per-pass session memory and aggregate budget tracking for API fallback approval.
    /// Reset by `beginAPIFallbackPass()` at the start of each Watch refresh.
    private var apiFallbackPassDenials: Set<DiscoveryTelemetryKind> = []
    private var apiFallbackPassApprovals: Set<DiscoveryTelemetryKind> = []
    private var apiFallbackPassUnitsSpent: Int = 0
    var apiFallbackPassActive: Bool = false
    private(set) var watchPoolByTopic: [Int64: [CandidateVideoViewModel]] = [:]
    private(set) var rankedWatchPool: [CandidateVideoViewModel] = []
    private(set) var storedCandidateVideosByTopic: [Int64: [CandidateVideoViewModel]] = [:]

    /// How many times each video has been shown "above the fold" in Watch.
    /// Incremented after each `rebuildWatchPools` for the top 12 ranked
    /// candidates. Used as a negative ranking signal at rerank time so
    /// repeatedly-surfaced videos gradually sink and new content rises.
    /// Persisted to UserDefaults so the signal survives app restarts.
    private(set) var watchImpressionCounts: [String: Int] = {
        guard let data = UserDefaults.standard.data(forKey: "watchImpressionCounts"),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }()

    // Cached flat video map — rebuilt on loadTopics()
    var videoMap: [String: VideoViewModel] = [:]
    var videoTopicMap: [String: Int64] = [:]
    private(set) var topicSearchFields: [Int64: [String]] = [:]
    var syncTask: Task<Void, Never>?
    var browserSyncTask: Task<Void, Never>?
    var syncLoopTask: Task<Void, Never>?
    var browserStatusTask: Task<Void, Never>?
    var watchRefreshTask: Task<Void, Never>?
    private var isUpdatingSelectionFromGrid = false
    private var apiFallbackApprovalContinuation: CheckedContinuation<Bool, Never>?

    let store: TopicStore
    var suggester: TopicSuggester?
    var creatorThemeClassifier: CreatorThemeClassifier?
    var youtubeClient: YouTubeClient?
    let runtimeEnvironment: RuntimeEnvironment

    /// Channels currently mid-classification, so the page view can show a loading
    /// indicator and prevent duplicate concurrent runs for the same creator.
    var classifyingThemeChannels: Set<String> = []

    /// Phase 3: channels currently mid "Load full upload history" scrape, so the
    /// creator detail page can show a progress indicator and prevent duplicate
    /// concurrent runs for the same creator.
    var loadingFullHistoryChannels: Set<String> = []

    /// Phase 3: result of the most recent full-history load per channel — count
    /// of NEW videos added on top of whatever was already in the archive. nil
    /// when no run has completed yet for this session. The view reads this to
    /// show "loaded N more videos" feedback after the spinner clears.
    var lastFullHistoryLoadCount: [String: Int] = [:]

    /// Phase 3: error reason for the most recent failed full-history load.
    /// Cleared when a load succeeds. Distinguishes "scraper found 0 new videos"
    /// (count == 0, no error) from "scraper failed silently" (count == 0 AND
    /// error is set). Surfaced inline in the empty-archive banner.
    var lastFullHistoryLoadError: [String: String] = [:]

    /// Phase 3: channels currently mid channel-link scrape (the small extra
    /// scrape that pulls external URLs from the channel's home page). Used by
    /// the view to suppress duplicate concurrent invocations and gate UI.
    var loadingChannelLinks: Set<String> = []

    /// Bumped after a channel-link scrape completes successfully so any open
    /// creator page can observe the change via .onChange and rebuild its
    /// page model from the freshly-cached links.
    var channelLinksVersion: Int = 0

    init(dbPath: String, claudeClient: ClaudeClient? = nil, startBackgroundTasks: Bool = true) throws {
        self.store = try TopicStore(path: dbPath)
        self.suggester = claudeClient.map { TopicSuggester(client: $0) }
        self.creatorThemeClassifier = claudeClient.map { CreatorThemeClassifier(client: $0) }
        self.youtubeClient = Self.makeYouTubeClient(context: "startup")
        self.runtimeEnvironment = RuntimeEnvironment()
        loadTopics()
        recoverInterruptedSyncActions(context: "startup")
        refreshSyncQueueSummary()
        refreshSeenHistoryCount()
        refreshExcludedCreators()
        refreshFavoriteCreators()
        // Phase 3 one-shot migration: rewrite historical archive rows where
        // published_at is a relative-date string ("5 years ago") into ISO 8601.
        // Gated by a UserDefaults flag so it only runs once per install.
        backfillArchivePublishedAtIfNeeded()
        if startBackgroundTasks {
            refreshBrowserExecutorStatus()
            processPendingSync(reason: "startup")
            processPendingBrowserSync(reason: "startup")
            startSyncLoop()
            // Offline-first channel avatars: download iconData blobs for any
            // known channel that doesn't have one yet. The blob is the
            // source of truth for ChannelIconView; without this, channels
            // discovered via topic/playlist sync (which populates iconUrl
            // but not iconData) would still hit the network on every
            // render and go blank when offline. Fire-and-forget — capped
            // per pass to avoid burst download on launch.
            backfillMissingChannelIcons()
        } else {
            browserExecutorStatusMessage = "Background sync disabled"
        }
    }

    /// Walk every channel in the SQLite channels table and download icon
    /// bytes for any channel that has an `iconUrl` but no cached `iconData`
    /// blob. Writes results back to SQLite via `updateChannelIcon` and
    /// refreshes the in-memory `knownChannelsById` cache for any channel
    /// already tracked there so subsequent renders pick up the new bytes
    /// without a roundtrip.
    ///
    /// This is the structural fix for offline channel avatars: every channel
    /// the user has *ever* touched (including pure-archive creators they've
    /// never saved into a topic) ends up with its icon stored locally, and
    /// `ChannelIconView` reads from that store first. Walking the full
    /// channels table — not just topic-referenced channels — closes the
    /// leaderboard / archive-discovery gap. Capped at 100 per pass so launch
    /// doesn't kick off a 500-icon download burst.
    func backfillMissingChannelIcons() {
        let allRecords: [ChannelRecord]
        do {
            allRecords = try store.allChannels()
        } catch {
            AppLogger.app.error("Channel icon backfill: failed to enumerate channels: \(error.localizedDescription, privacy: .public)")
            return
        }
        let candidates = allRecords.filter { record in
            record.iconData == nil && record.iconUrl != nil
        }
        guard !candidates.isEmpty else { return }
        let capped = Array(candidates.prefix(100))
        AppLogger.app.info("Backfilling \(capped.count, privacy: .public) missing channel icons (of \(candidates.count, privacy: .public) needing icons across \(allRecords.count, privacy: .public) total channels)")

        Task { [weak self] in
            guard let self else { return }
            await self.runChannelIconBackfill(records: capped)
        }
    }

    private func runChannelIconBackfill(records: [ChannelRecord]) async {
        var fetched = 0
        for record in records {
            guard let urlString = record.iconUrl, let url = URL(string: urlString) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      !data.isEmpty else { continue }
                try store.updateChannelIcon(channelId: record.channelId, iconData: data)
                if let refreshed = (try? store.channelById(record.channelId)) ?? nil {
                    knownChannelsById[record.channelId] = refreshed
                }
                fetched += 1
            } catch {
                // Silently skip — we'll retry on next launch.
            }
        }
        if fetched > 0 {
            AppLogger.app.info("Channel icon backfill cached \(fetched, privacy: .public) icons")
        }
    }

    func stopBackgroundTasks() {
        syncTask?.cancel()
        syncTask = nil
        browserSyncTask?.cancel()
        browserSyncTask = nil
        syncLoopTask?.cancel()
        syncLoopTask = nil
        browserStatusTask?.cancel()
        browserStatusTask = nil
        watchRefreshTask?.cancel()
        watchRefreshTask = nil
        apiFallbackApprovalContinuation?.resume(returning: false)
        apiFallbackApprovalContinuation = nil
        pendingAPIFallbackApproval = nil
        apiFallbackPassActive = false
    }

    func refreshCredentialBackedClients() {
        let client = Self.makeClaudeClient(context: "credentials refresh")
        suggester = client.map { TopicSuggester(client: $0) }
        creatorThemeClassifier = client.map { CreatorThemeClassifier(client: $0) }
        youtubeClient = Self.makeYouTubeClient(context: "credentials refresh")
        AppLogger.auth.info("Refreshed credential-backed service clients")
    }

    private static func makeClaudeClient(context: String) -> ClaudeClient? {
        do {
            return try ClaudeClient()
        } catch {
            AppLogger.auth.info("Claude client unavailable during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func makeYouTubeClient(context: String) -> YouTubeClient? {
        do {
            return try YouTubeClient()
        } catch {
            AppLogger.auth.info("YouTube client unavailable during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func refreshExcludedCreators() {
        do {
            excludedCreators = try store.excludedChannelsList()
        } catch {
            AppLogger.app.error("Failed to load excluded creators: \(error.localizedDescription, privacy: .public)")
            excludedCreators = []
        }
    }

    func refreshYouTubeQuotaSnapshot() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.youtubeQuotaSnapshot = await YouTubeQuotaLedger.shared.snapshot()
            self.scrapeHealth = await YouTubeQuotaLedger.shared.scrapeHealth()
        }
    }

    /// Phase 3: refresh just the scrape health pill, without re-fetching the
    /// quota snapshot. Called inline after every scrape attempt completes so
    /// the UI updates immediately. Cheap — pure in-memory event filter.
    func refreshScrapeHealth() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scrapeHealth = await YouTubeQuotaLedger.shared.scrapeHealth()
        }
    }

    /// Marks the start of a new Watch refresh pass and clears all per-pass approval state.
    func beginAPIFallbackPass() {
        apiFallbackPassDenials.removeAll()
        apiFallbackPassApprovals.removeAll()
        apiFallbackPassUnitsSpent = 0
        apiFallbackPassActive = true
    }

    /// Marks the end of a Watch refresh pass. Called from a defer block.
    func endAPIFallbackPass() {
        apiFallbackPassActive = false
    }

    /// Request approval for an API fallback. Honors per-pass session memory, the per-pass
    /// aggregate budget, and the search-fallback opt-in. Returns true if the call may proceed.
    func requestAPIFallbackApproval(
        kind: DiscoveryTelemetryKind,
        reason: String,
        operation: YouTubeAPIOperation
    ) async -> Bool {
        // Fix 1: search.list API fallback is opt-in via Settings.
        if kind == .search && !apiSearchFallbackEnabled {
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: kind,
                backend: .api,
                outcome: .skipped,
                detail: "search API fallback disabled in Settings"
            )
            return false
        }

        // Fix 2: per-pass denial memory.
        if apiFallbackPassDenials.contains(kind) {
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: kind,
                backend: .api,
                outcome: .skipped,
                detail: "denied for this refresh pass"
            )
            return false
        }

        // Fix 5: per-pass aggregate budget. Reject before prompting if this call would
        // exceed the ceiling — protects against runaway approvals.
        let projected = apiFallbackPassUnitsSpent + operation.estimatedUnits
        if apiFallbackPassActive && projected > apiFallbackPassBudgetUnits {
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: kind,
                backend: .api,
                outcome: .skipped,
                detail: "per-pass budget exceeded (\(apiFallbackPassUnitsSpent)/\(apiFallbackPassBudgetUnits) units spent, +\(operation.estimatedUnits) needed)"
            )
            return false
        }

        // Fix 2: per-pass approval memory — auto-approve subsequent calls of the same kind.
        if apiFallbackPassApprovals.contains(kind) {
            apiFallbackPassUnitsSpent += operation.estimatedUnits
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: kind,
                backend: .api,
                outcome: .approvalGranted,
                detail: "auto-approved for this pass: \(reason)"
            )
            return true
        }

        let snapshot = await YouTubeQuotaLedger.shared.snapshot()
        await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
            kind: kind,
            backend: .api,
            outcome: .approvalRequested,
            detail: reason
        )

        if let existing = apiFallbackApprovalContinuation {
            existing.resume(returning: false)
            apiFallbackApprovalContinuation = nil
        }

        youtubeQuotaSnapshot = snapshot
        pendingAPIFallbackApproval = APIFallbackApprovalRequest(
            title: "Use YouTube API?",
            reason: reason,
            operation: operation,
            estimatedUnits: operation.estimatedUnits,
            remainingUnitsToday: snapshot.remainingUnitsToday,
            resetAt: snapshot.resetAt,
            kind: kind,
            passUnitsSpent: apiFallbackPassUnitsSpent,
            passBudgetUnits: apiFallbackPassBudgetUnits,
            passActive: apiFallbackPassActive
        )

        return await withCheckedContinuation { continuation in
            apiFallbackApprovalContinuation = continuation
        }
    }

    func approvePendingAPIFallback(rememberForPass: Bool = false) {
        guard let request = pendingAPIFallbackApproval else { return }
        pendingAPIFallbackApproval = nil
        let continuation = apiFallbackApprovalContinuation
        apiFallbackApprovalContinuation = nil
        if apiFallbackPassActive {
            apiFallbackPassUnitsSpent += request.estimatedUnits
            if rememberForPass {
                apiFallbackPassApprovals.insert(request.kind)
            }
        }
        Task {
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: request.kind,
                backend: .api,
                outcome: .approvalGranted,
                detail: rememberForPass ? "remembered for pass: \(request.reason)" : request.reason
            )
        }
        continuation?.resume(returning: true)
    }

    func denyPendingAPIFallback(rememberForPass: Bool = false) {
        guard let request = pendingAPIFallbackApproval else { return }
        pendingAPIFallbackApproval = nil
        let continuation = apiFallbackApprovalContinuation
        apiFallbackApprovalContinuation = nil
        if apiFallbackPassActive && rememberForPass {
            apiFallbackPassDenials.insert(request.kind)
        }
        Task {
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: request.kind,
                backend: .api,
                outcome: .approvalDenied,
                detail: rememberForPass ? "remembered for pass: \(request.reason)" : request.reason
            )
        }
        continuation?.resume(returning: false)
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

    /// What the inspector should render for the current selection state.
    /// Three discrete cases — empty, single video, multi-selection — so the
    /// inspector can dispatch on a single source of truth instead of
    /// guessing from a pile of optional flags.
    ///
    /// **Hover always wins.** When the user is hovering a card, the inspector
    /// shows that single video as a preview, even if there's an explicit
    /// multi-selection underneath. This matches the existing single-video
    /// behavior — hover is "show me what's under my cursor", multi is "act
    /// on the explicit set." They don't fight; hover takes priority.
    var inspectedSelection: InspectedSelection {
        // Hover takes priority — single preview wins over multi.
        if hoveredVideoId != nil, let item = inspectedItem {
            return .single(item)
        }

        // No hover: route based on the explicit selection set.
        if selectedVideoIds.count >= 2 {
            let videos = selectedVideoIds.compactMap { videoMap[$0] }
            if videos.count >= 2 {
                return .multiple(videos)
            }
        }

        if let item = inspectedItem {
            return .single(item)
        }

        return .empty
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
    var knownChannelsById: [String: ChannelRecord] = [:]

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
        } else {
            // Cancel background watch refresh when leaving Watch mode
            watchRefreshTask?.cancel()
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

        // Stable update: only replace per-topic pools that actually changed.
        // This prevents SwiftUI observation from firing for topics whose
        // header/face-pile didn't change, which was causing visible churn
        // in the topic header when unrelated topics refreshed in the
        // background. Value comparison uses the video ID set as a cheap
        // proxy — if the same videos are in the pool, skip the update.
        for (topicId, newPool) in assigned {
            let oldIds = Set((watchPoolByTopic[topicId] ?? []).map(\.videoId))
            let newIds = Set(newPool.map(\.videoId))
            if oldIds != newIds {
                watchPoolByTopic[topicId] = newPool
            }
        }
        // Remove topics that are no longer in the assignment
        for topicId in watchPoolByTopic.keys where assigned[topicId] == nil {
            watchPoolByTopic.removeValue(forKey: topicId)
        }

        rankedWatchPool = CandidateDiscoveryCoordinator.rerankWatchVideos(
            topics.flatMap { assigned[$0.id] ?? [] },
            store: self
        )

        // Track impressions for the top 12 "above the fold" candidates.
        // Each appearance increments the counter, which feeds back into
        // the reranking penalty on the next rebuild. Prune entries for
        // videos no longer in the pool to prevent unbounded growth.
        let aboveTheFold = rankedWatchPool.prefix(12)
        for video in aboveTheFold {
            watchImpressionCounts[video.videoId, default: 0] += 1
        }
        let activeIds = Set(rankedWatchPool.map(\.videoId))
        watchImpressionCounts = watchImpressionCounts.filter { activeIds.contains($0.key) }
        if let data = try? JSONEncoder().encode(watchImpressionCounts) {
            UserDefaults.standard.set(data, forKey: "watchImpressionCounts")
        }

        watchPoolVersion &+= 1
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

        // Phase 3: topics that contain a favorited creator's videos get priority in
        // the refresh order, right after the user's currently-visible context. This
        // means a fresh launch with one Pin set will refresh that creator's topics
        // before walking the rest of the library.
        let favoriteIds = Set(favoriteCreators.map(\.channelId))
        if !favoriteIds.isEmpty {
            let favoriteTopicIds = topicChannels
                .compactMap { topicId, channels -> Int64? in
                    let hasFavorite = channels.contains { favoriteIds.contains($0.channelId) }
                    return hasFavorite && remaining.contains(topicId) ? topicId : nil
                }
            favoriteTopicIds.forEach { appendIfEligible($0) }
        }

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
        let text = searchText
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // If the LAST token in the search text starts with `from:`, dispatch to the
        // creator-aware typeahead instead of the general one. The user is filling in
        // a creator name/handle and shouldn't see topic/channel suggestions for the
        // unrelated terms before it.
        if let partial = currentFromCreatorPartial(in: text) {
            return fromCreatorSuggestions(partial: partial, limit: limit)
        }

        // Don't show suggestions for exclude terms
        guard !trimmed.hasPrefix("-") else { return [] }
        guard trimmed.count >= 2 else { return [] }

        var results: [TypeaheadSuggestion] = []

        // Match topics and subtopics
        for topic in topics {
            if topic.name.localizedStandardContains(trimmed) {
                results.append(TypeaheadSuggestion(
                    kind: .topic,
                    text: topic.name,
                    count: topic.videoCount,
                    topicId: topic.id
                ))
            }
            for sub in topic.subtopics where sub.name.localizedStandardContains(trimmed) {
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
        for (channel, count) in channelCounts where channel.localizedStandardContains(trimmed) {
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

    /// Extracts the partial text after a `from:` operator at the end of the search
    /// input. Returns nil if no such token exists. Activates immediately on `from:`
    /// (empty partial) so the user sees a list of all known creators ranked by
    /// video count, then narrows as they type.
    func currentFromCreatorPartial(in text: String) -> String? {
        let lastToken = text.split(separator: " ", omittingEmptySubsequences: false).last ?? ""
        guard lastToken.hasPrefix("from:") else { return nil }
        var partial = String(lastToken.dropFirst("from:".count))
        // Strip optional opening quote so `from:"par` becomes `par`.
        if partial.hasPrefix("\"") {
            partial.removeFirst()
        }
        return partial
    }

    /// Returns creator suggestions matching the partial after a `from:` token.
    /// Substring matches against both the channel display name AND the YouTube
    /// handle, ranked by saved video count. The handle is preserved on the
    /// suggestion so the selection handler can insert the canonical `from:@handle`
    /// form back into the search box.
    private func fromCreatorSuggestions(partial: String, limit: Int) -> [TypeaheadSuggestion] {
        // Build a deduped channel list from the topicChannels cache.
        var seen = Set<String>()
        var channels: [(record: ChannelRecord, count: Int)] = []
        for channelList in topicChannels.values {
            for record in channelList where seen.insert(record.channelId).inserted {
                let count = channelCounts[record.name] ?? 0
                channels.append((record, count))
            }
        }

        // Empty partial → show top creators by saved count.
        let needle = partial.trimmingCharacters(in: .whitespaces)
        let matched: [(record: ChannelRecord, count: Int)]
        if needle.isEmpty {
            matched = channels
        } else {
            let lowered = needle.lowercased()
            matched = channels.filter { entry in
                let nameMatch = entry.record.name.lowercased().contains(lowered)
                let handleMatch = entry.record.handle?.lowercased().contains(lowered) ?? false
                return nameMatch || handleMatch
            }
        }

        let sorted = matched.sorted { $0.count > $1.count }
        return sorted.prefix(limit).map { entry in
            TypeaheadSuggestion(
                kind: .fromCreator,
                text: entry.record.name,
                count: entry.count,
                topicId: nil,
                parentName: nil,
                handle: entry.record.handle
            )
        }
    }

    // Topic CRUD and AI operations extracted to OrganizerStore+TopicCRUD.swift
}
