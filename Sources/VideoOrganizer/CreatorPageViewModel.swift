import Foundation
import TaggingKit

// MARK: - Page-level model

/// Aggregate model for the creator detail page (Phase 1 sections only).
///
/// Built once per page open by `CreatorPageBuilder.makePage(for:in:)` from data already
/// in memory in the `OrganizerStore`. No async, no LLM, no network — every field is a
/// pure transform of saved videos, the channel discovery archive, the channel record
/// cache, and the playlist memberships map.
///
/// The model is intentionally a value type with no `@Observable` machinery: the page
/// re-builds the whole model on `.task(id: channelId)` and on action callbacks
/// (favorite/exclude). Diffs are cheap and cache invalidation stays local.
struct CreatorPageViewModel {
    // Identity
    let channelId: String
    let channelName: String
    let subtitle: String?              // first sentence of channel description
    let creatorTier: String?           // small/growing/mid-tier/large/mega
    let avatarData: Data?
    let avatarUrl: URL?
    let countryDisplayName: String?    // not yet sourced — placeholder for Phase 1
    let foundingYear: Int?             // derived from oldest known publish date

    // Header chips
    let savedVideoCount: Int
    let watchedVideoCount: Int
    let subscriberCountFormatted: String?
    let lastUploadAge: String?
    let totalViewsFormatted: String

    // Outlier baseline used by the page; surfaced for tooltips/debugging.
    let channelMedianViews: Int

    // Phase 3: Their hits — top videos by raw outlier score, no recency tilt.
    // Distinct from Essentials, which IS recency-weighted. The hits view answers
    // "what's their best work regardless of when it dropped" — useful when
    // researching a creator's catalog historically.
    let theirHits: [CreatorVideoCard]

    // What's new
    let latestVideo: CreatorVideoCard?

    // Recent uploads window (last 14 days, capped at 5).
    // - 0 in window → empty array (caller falls back to latestVideo single-row treatment)
    // - 1 in window → one item; section header reads "What's new"
    // - 2-5 in window → all items rendered as a grid; section header reads
    //   "Recent uploads · last 14 days"
    // - 6+ in window → first 5 items; caller surfaces "+ N more" affordance
    let recentVideos: [CreatorVideoCard]
    let recentVideosTotalInWindow: Int

    // Essentials (curated 6-8 by outlier score with recency weighting)
    let essentials: [CreatorVideoCard]

    // All videos (saved + archive merged, sorted by date desc by default)
    let allVideos: [CreatorVideoCard]

    // Playlists this creator's videos appear in
    let playlists: [CreatorPlaylistEntry]

    // Niche fingerprint
    let topicShare: [CreatorTopicShare]
    /// Phase 3: same shape as `topicShare` but computed only over saved videos
    /// published in the last 365 days. Lets the user flip the topic share chart
    /// between "all time" and "last 12 months" to see if the niche has shifted.
    /// Empty when the creator has no recent saved videos with parseable dates.
    let topicShareLast12Months: [CreatorTopicShare]

    // Top creators in this niche — pre-computed per-topic dominance leaderboard.
    // The view picks one scope topic at a time (default = leaderboardDefaultTopicId)
    // and one ranking metric (saved / outliers / views) and reads the matching entries.
    // Capped at 10 entries per topic. Includes the page creator themselves so they
    // can see where they rank.
    let leaderboardScopes: [CreatorLeaderboardScope]
    let leaderboardByTopic: [Int64: [CreatorLeaderboardEntry]]
    let leaderboardDefaultTopicId: Int64?

    // Phase 2 LLM-cached enrichments. Empty when the toggle is off OR cache is empty.
    let themes: [CreatorThemeRecord]
    let aboutParagraph: String?
    let isClassifyingThemes: Bool
    /// Phase 3: per-series standout episode lookup. For each theme cluster where
    /// `isSeries == true`, this map contains the videoId of the cluster member with
    /// the highest series-scoped outlier score (views relative to the SERIES median,
    /// not the channel median). Used by the "By theme" section to badge the standout.
    let standoutEpisodesBySeriesLabel: [String: String]

    // Cadence: videos per month for the last 24 months
    let monthlyVideoCounts: [CreatorMonthlyCount]

    // Channel information
    let totalUploadsKnown: Int          // saved + archive count we know about
    let totalUploadsReported: Int?      // from channel record (may exceed knownTotal)
    let coveragePercent: Double?        // saved / totalUploadsReported
    let channelCreatedDate: Date?       // best-effort; nil when unknown
    let lastRefreshedAt: Date?
    let youtubeURL: URL

    // State
    let isFavorite: Bool
    let isExcluded: Bool
    /// Phase 3: free-text notes the user has saved on this creator. nil when not
    /// favorited or when no notes have been written. Stored in the favorite_channels
    /// table (column existed since Phase 1 #3, surfaced in UI now in Phase 3).
    let notes: String?

    /// Phase 3: count of uploads (saved + archive) published after the user's
    /// previous visit to this creator's detail page. Computed from the
    /// `favorite_channels.last_visited_at` timestamp captured BEFORE the current
    /// visit bumped it. Always 0 for non-favorited creators (no row to read from)
    /// and for first visits where there's no prior timestamp.
    let newSinceLastVisitCount: Int

    /// Phase 3: ISO8601 timestamp of the previous visit (the value of
    /// last_visited_at before this page open bumped it). nil on first visit.
    let previousVisitDate: Date?

    init(
        channelId: String,
        channelName: String,
        subtitle: String?,
        creatorTier: String?,
        avatarData: Data?,
        avatarUrl: URL?,
        countryDisplayName: String?,
        foundingYear: Int?,
        savedVideoCount: Int,
        watchedVideoCount: Int,
        subscriberCountFormatted: String?,
        lastUploadAge: String?,
        totalViewsFormatted: String,
        channelMedianViews: Int,
        theirHits: [CreatorVideoCard],
        latestVideo: CreatorVideoCard?,
        recentVideos: [CreatorVideoCard],
        recentVideosTotalInWindow: Int,
        essentials: [CreatorVideoCard],
        allVideos: [CreatorVideoCard],
        playlists: [CreatorPlaylistEntry],
        topicShare: [CreatorTopicShare],
        topicShareLast12Months: [CreatorTopicShare],
        leaderboardScopes: [CreatorLeaderboardScope],
        leaderboardByTopic: [Int64: [CreatorLeaderboardEntry]],
        leaderboardDefaultTopicId: Int64?,
        themes: [CreatorThemeRecord],
        aboutParagraph: String?,
        isClassifyingThemes: Bool,
        standoutEpisodesBySeriesLabel: [String: String],
        monthlyVideoCounts: [CreatorMonthlyCount],
        totalUploadsKnown: Int,
        totalUploadsReported: Int?,
        coveragePercent: Double?,
        channelCreatedDate: Date?,
        lastRefreshedAt: Date?,
        youtubeURL: URL,
        isFavorite: Bool,
        isExcluded: Bool,
        notes: String?,
        newSinceLastVisitCount: Int = 0,
        previousVisitDate: Date? = nil
    ) {
        self.channelId = channelId
        self.channelName = channelName
        self.subtitle = subtitle
        self.creatorTier = creatorTier
        self.avatarData = avatarData
        self.avatarUrl = avatarUrl
        self.countryDisplayName = countryDisplayName
        self.foundingYear = foundingYear
        self.savedVideoCount = savedVideoCount
        self.watchedVideoCount = watchedVideoCount
        self.subscriberCountFormatted = subscriberCountFormatted
        self.lastUploadAge = lastUploadAge
        self.totalViewsFormatted = totalViewsFormatted
        self.channelMedianViews = channelMedianViews
        self.theirHits = theirHits
        self.latestVideo = latestVideo
        self.recentVideos = recentVideos
        self.recentVideosTotalInWindow = recentVideosTotalInWindow
        self.essentials = essentials
        self.allVideos = allVideos
        self.playlists = playlists
        self.topicShare = topicShare
        self.topicShareLast12Months = topicShareLast12Months
        self.leaderboardScopes = leaderboardScopes
        self.leaderboardByTopic = leaderboardByTopic
        self.leaderboardDefaultTopicId = leaderboardDefaultTopicId
        self.themes = themes
        self.aboutParagraph = aboutParagraph
        self.isClassifyingThemes = isClassifyingThemes
        self.standoutEpisodesBySeriesLabel = standoutEpisodesBySeriesLabel
        self.monthlyVideoCounts = monthlyVideoCounts
        self.totalUploadsKnown = totalUploadsKnown
        self.totalUploadsReported = totalUploadsReported
        self.coveragePercent = coveragePercent
        self.channelCreatedDate = channelCreatedDate
        self.lastRefreshedAt = lastRefreshedAt
        self.youtubeURL = youtubeURL
        self.isFavorite = isFavorite
        self.isExcluded = isExcluded
        self.notes = notes
        self.newSinceLastVisitCount = newSinceLastVisitCount
        self.previousVisitDate = previousVisitDate
    }

    static let placeholderEmpty = CreatorPageViewModel(
        channelId: "",
        channelName: "Unknown",
        subtitle: nil,
        creatorTier: nil,
        avatarData: nil,
        avatarUrl: nil,
        countryDisplayName: nil,
        foundingYear: nil,
        savedVideoCount: 0,
        watchedVideoCount: 0,
        subscriberCountFormatted: nil,
        lastUploadAge: nil,
        totalViewsFormatted: "0 views",
        channelMedianViews: 0,
        theirHits: [],
        latestVideo: nil,
        recentVideos: [],
        recentVideosTotalInWindow: 0,
        essentials: [],
        allVideos: [],
        playlists: [],
        topicShare: [],
        topicShareLast12Months: [],
        leaderboardScopes: [],
        leaderboardByTopic: [:],
        leaderboardDefaultTopicId: nil,
        themes: [],
        aboutParagraph: nil,
        isClassifyingThemes: false,
        standoutEpisodesBySeriesLabel: [:],
        monthlyVideoCounts: [],
        totalUploadsKnown: 0,
        totalUploadsReported: nil,
        coveragePercent: nil,
        channelCreatedDate: nil,
        lastRefreshedAt: nil,
        youtubeURL: URL(string: "https://www.youtube.com")!,
        isFavorite: false,
        isExcluded: false,
        notes: nil
    )
}

// MARK: - Cards

struct CreatorVideoCard: Identifiable, Equatable {
    let videoId: String
    let title: String
    let thumbnailUrl: URL?
    let topicName: String?
    let topicId: Int64?
    let viewCountFormatted: String
    let viewCountParsed: Int
    let runtimeFormatted: String?
    let publishedAt: String?
    let ageDays: Int?
    let ageFormatted: String?
    let isSaved: Bool
    let outlierScore: Double
    let isOutlier: Bool

    var id: String { videoId }

    var youtubeUrl: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoId)")
    }
}

extension CreatorVideoCard: OutlierAnalyzable {
    var outlierViewCount: Int? {
        viewCountParsed > 0 ? viewCountParsed : nil
    }

    var outlierAgeDays: Int? {
        ageDays
    }
}

struct CreatorPlaylistEntry: Identifiable, Equatable {
    let playlist: PlaylistRecord
    let creatorVideoCount: Int

    var id: String { playlist.playlistId }

    static func == (lhs: CreatorPlaylistEntry, rhs: CreatorPlaylistEntry) -> Bool {
        lhs.playlist.playlistId == rhs.playlist.playlistId
            && lhs.creatorVideoCount == rhs.creatorVideoCount
    }
}

struct CreatorTopicShare: Identifiable, Equatable {
    let topicId: Int64
    let topicName: String
    let videoCount: Int
    let percentage: Double
    /// Phase 3: this creator's saved videos as a fraction of ALL saved videos in
    /// the topic across every creator the user has. 0.0–1.0. Tells you "how much of
    /// this topic does this creator own?"
    let shareOfVoice: Double
    /// Total saved videos in the topic across all creators (denominator for shareOfVoice).
    /// Surfaced for tooltips so the user can see the absolute numbers.
    let topicTotalSavedCount: Int

    var id: Int64 { topicId }
}

struct CreatorMonthlyCount: Identifiable, Equatable {
    let month: Date
    let count: Int

    var id: Date { month }
}

/// One creator's row in the niche dominance leaderboard for a single TOPIC scope.
/// All counts and totals are scoped to one topic at a time — switching the scope
/// rebuilds the entries from `leaderboardByTopic`. The leaderboard shows
/// "who dominates this niche" via three pre-computed metrics the user can rank by.
struct CreatorLeaderboardEntry: Identifiable, Equatable {
    let channelId: String
    let channelName: String
    let channelIconUrl: URL?
    /// Number of saved videos this creator has IN THE SCOPE TOPIC.
    let savedVideoCount: Int
    /// Number of videos in the scope topic that qualify as outliers — `views >= 3×`
    /// this creator's own channel median across all known videos. Reuses the Phase 1
    /// OutlierAnalytics primitive.
    let outlierVideoCount: Int
    /// Sum of parsed view counts of this creator's videos in the scope topic.
    let totalViewsInTopic: Int
    /// Subscriber count formatted for the secondary subtitle line. NOT used for ranking
    /// (the plan explicitly rejected global subscriber-count framing — see Appendix B).
    let subscriberCountFormatted: String?
    /// True for the row representing the creator whose page is currently shown.
    /// Drives the highlight so the user can see where the page creator sits.
    let isPageCreator: Bool

    var id: String { channelId }
}

/// Eligible scope option for the leaderboard topic picker. One of the page creator's
/// topics. The default scope is the topic with the most of the page creator's saved
/// videos (their primary topic).
struct CreatorLeaderboardScope: Identifiable, Equatable {
    let topicId: Int64
    let topicName: String
    /// Number of distinct creators in the user's library who publish in this topic
    /// (including the page creator). Surfaced in the picker label so the user knows
    /// which topics actually have a meaningful leaderboard.
    let creatorCount: Int

    var id: Int64 { topicId }
}

// MARK: - Builder

enum CreatorPageBuilder {
    /// Builds a fully-populated creator page model from data already in memory.
    /// All inputs come from the `OrganizerStore` cache — no async, no I/O.
    @MainActor
    static func makePage(forChannelId channelId: String, in store: OrganizerStore) -> CreatorPageViewModel {
        // Phase 3 perf instrumentation: time the full build and the major helpers
        // so we can spot regressions. Logged to AppLogger.file (debug.log) so the
        // numbers can be retrieved offline by reading the file directly — OSLog
        // is unreliable for this because of system filtering and the absence of
        // a way to scrape it from outside Console.app.
        let buildStart = CFAbsoluteTimeGetCurrent()
        defer {
            let totalMs = (CFAbsoluteTimeGetCurrent() - buildStart) * 1_000
            AppLogger.file.log("CreatorPageBuilder.makePage(\(channelId)) total=\(String(format: "%.1f", totalMs))ms", category: "perf")
        }

        // 1. Resolve channel record (used for subtitle, avatar, subscriber count, country, etc.)
        let channelRecord = store.topicChannels.values
            .flatMap { $0 }
            .first(where: { $0.channelId == channelId })

        // 2. Walk every topic and collect this creator's saved videos, indexed by topic.
        var savedByTopic: [(topic: TopicViewModel, videos: [VideoViewModel])] = []
        for topic in store.topics {
            let videos = store.videosForTopicIncludingSubtopics(topic.id)
                .filter { $0.channelId == channelId }
            if !videos.isEmpty {
                savedByTopic.append((topic, videos))
            }
        }
        let savedVideosFlat = savedByTopic.flatMap { $0.videos }
        let savedVideoIds = Set(savedVideosFlat.map(\.videoId))

        // 3. Pull the channel discovery archive (most recent ~24 uploads we know about).
        let archive: [ArchivedChannelVideo]
        do {
            archive = try store.store.archivedVideosForChannels([channelId], perChannelLimit: 32)
        } catch {
            AppLogger.app.error("CreatorPageBuilder failed to fetch archive for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            archive = []
        }

        // 4. Resolve display name. Prefer the channel record, fall back to first saved
        //    video, then to the archive, then to "Unknown".
        let resolvedName = channelRecord?.name
            ?? savedVideosFlat.first?.channelName
            ?? archive.first?.channelName
            ?? "Unknown"

        // 5. Build the unified card list (saved + archive de-duped on videoId, saved wins).
        let allCards = makeAllCards(
            savedByTopic: savedByTopic,
            savedVideoIds: savedVideoIds,
            archive: archive
        )

        // 6. Per-creator outlier baseline.
        let medianViews = OutlierAnalytics.channelMedianViews(allCards)

        // 7. Re-derive cards with outlier scoring against the baseline.
        let scoredCards = allCards.map { card -> CreatorVideoCard in
            let score = OutlierAnalytics.outlierScore(views: card.viewCountParsed, channelMedian: medianViews)
            return CreatorVideoCard(
                videoId: card.videoId,
                title: card.title,
                thumbnailUrl: card.thumbnailUrl,
                topicName: card.topicName,
                topicId: card.topicId,
                viewCountFormatted: card.viewCountFormatted,
                viewCountParsed: card.viewCountParsed,
                runtimeFormatted: card.runtimeFormatted,
                publishedAt: card.publishedAt,
                ageDays: card.ageDays,
                ageFormatted: card.ageFormatted,
                isSaved: card.isSaved,
                outlierScore: score,
                isOutlier: score >= OutlierAnalytics.defaultOutlierThreshold
            )
        }

        // 8. Sort the canonical "all videos" list by recency (newest first).
        let allVideos = scoredCards.sorted { lhs, rhs in
            switch (lhs.ageDays, rhs.ageDays) {
            case let (l?, r?):
                return l < r
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }

        // 9. Essentials = top outliers (Phase 1 algorithm in OutlierAnalytics).
        let essentials = OutlierAnalytics.topOutliers(scoredCards, limit: 8)

        // 9b. Phase 3: "Their hits" — pure outlier ranking, no recency weighting.
        // Distinct from Essentials which favors recent work. Hits answers
        // "what's their best work, ever". Sort by raw outlierScore descending,
        // tiebreaker by raw view count.
        let theirHits = scoredCards
            .filter { $0.outlierScore > 0 }
            .sorted { lhs, rhs in
                if lhs.outlierScore != rhs.outlierScore {
                    return lhs.outlierScore > rhs.outlierScore
                }
                return lhs.viewCountParsed > rhs.viewCountParsed
            }
            .prefix(8)
            .map { $0 }

        // 10. Latest video = most recent by publishedAt.
        let latestVideo = allVideos.first

        // 10b. Recent uploads window = last 14 days, capped at 5.
        let recentVideosInWindow = allVideos.filter { card in
            guard let ageDays = card.ageDays else { return false }
            return ageDays <= 14
        }
        let recentVideos = Array(recentVideosInWindow.prefix(5))
        let recentVideosTotalInWindow = recentVideosInWindow.count

        // 10c. Phase 2 LLM theme cache + Phase 3 series-scoped standout computation.
        let cachedThemes = (try? store.store.creatorThemes(channelId: channelId)) ?? []

        // 11. Header counts and totals.
        let totalViews = scoredCards.reduce(0) { $0 + $1.viewCountParsed }
        let watchedCount = savedVideosFlat.compactMap { store.seenSummary(for: $0.videoId) }.count

        // 12. Topic share (only counts saved videos by topic — archive isn't topic-tagged).
        let topicShareStart = CFAbsoluteTimeGetCurrent()
        let topicShare = makeTopicShare(savedByTopic: savedByTopic, store: store)
        // 12b. Recency-weighted variant: same shape, but only counts videos
        // published in the last 365 days. Used by the topic share toggle so the
        // user can see if the creator's niche mix has shifted recently.
        let topicShareLast12Months = makeTopicShare(
            savedByTopic: filterSavedByTopicToRecentYear(savedByTopic),
            store: store
        )
        AppLogger.file.log("  topicShare(both)=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - topicShareStart) * 1_000))ms", category: "perf")

        // 13. Monthly cadence (last 24 months) — use parseISO8601 dates from publishedAt.
        let cadenceStart = CFAbsoluteTimeGetCurrent()
        let monthlyCounts = makeMonthlyCounts(from: scoredCards)
        AppLogger.file.log("  monthlyCounts=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - cadenceStart) * 1_000))ms cards=\(scoredCards.count)", category: "perf")

        // 14. Playlists this creator's videos appear in.
        let playlistsStart = CFAbsoluteTimeGetCurrent()
        let playlists = makePlaylists(savedVideos: savedVideosFlat, store: store)
        AppLogger.file.log("  playlists=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - playlistsStart) * 1_000))ms", category: "perf")

        // 15. Channel info bottom section.
        let totalUploadsReported = channelRecord?.videoCountTotal
        let coverage: Double? = {
            guard let total = totalUploadsReported, total > 0 else { return nil }
            return Double(savedVideosFlat.count) / Double(total)
        }()

        let lastUploadAge = latestVideo?.ageFormatted
        let foundingYear = computeFoundingYear(from: scoredCards)

        let youtubeURL = URL(string: "https://www.youtube.com/channel/\(channelId)")
            ?? URL(string: "https://www.youtube.com")!

        // Avatar URL: prefer the channel record, fall back to the first saved video's
        // channelIconUrl. Never fall back to a video's thumbnail (a different image).
        // The URL is upscaled at render time via upscaledAvatarURL — YouTube serves the
        // same image at higher resolution by changing the =sNNN size parameter.
        let rawAvatarUrl = channelRecord?.iconUrl
            ?? savedVideosFlat.first(where: { $0.channelIconUrl != nil })?.channelIconUrl
        let avatarURL = rawAvatarUrl
            .map(CreatorPageBuilder.upscaledAvatarURL)
            .flatMap(URL.init(string:))

        // Leaderboard build is the largest single helper — instrument it
        // separately so we can see its contribution to the total build cost.
        let leaderboardStart = CFAbsoluteTimeGetCurrent()
        let leaderboardScopes = makeLeaderboardScopes(forChannelId: channelId, in: store)
        let leaderboardByTopic = makeLeaderboardByTopic(forChannelId: channelId, in: store)
        let leaderboardDefaultTopicId = makeLeaderboardDefaultTopicId(forChannelId: channelId, savedByTopic: savedByTopic)
        AppLogger.file.log("  leaderboard=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - leaderboardStart) * 1_000))ms scopes=\(leaderboardScopes.count)", category: "perf")

        // Phase 3 visit tracking — single read+parse, then reuse for both fields.
        let visitStart = CFAbsoluteTimeGetCurrent()
        let prevVisit = previousVisitDate(channelId: channelId, store: store)
        let newSinceCount = makeNewSinceLastVisitCount(
            cutoff: prevVisit,
            allCards: scoredCards
        )
        AppLogger.file.log("  visitTracking=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - visitStart) * 1_000))ms hadPriorVisit=\(prevVisit != nil)", category: "perf")

        return CreatorPageViewModel(
            channelId: channelId,
            channelName: resolvedName,
            subtitle: makeSubtitle(from: channelRecord),
            creatorTier: creatorTier(from: channelRecord?.subscriberCount),
            avatarData: channelRecord?.iconData,
            avatarUrl: avatarURL,
            countryDisplayName: nil, // not yet sourced
            foundingYear: foundingYear,
            savedVideoCount: savedVideosFlat.count,
            watchedVideoCount: watchedCount,
            subscriberCountFormatted: formatSubscriberCount(channelRecord?.subscriberCount),
            lastUploadAge: lastUploadAge,
            totalViewsFormatted: formatViewTotal(totalViews),
            channelMedianViews: medianViews,
            theirHits: Array(theirHits),
            latestVideo: latestVideo,
            recentVideos: recentVideos,
            recentVideosTotalInWindow: recentVideosTotalInWindow,
            essentials: essentials,
            allVideos: allVideos,
            playlists: playlists,
            topicShare: topicShare,
            topicShareLast12Months: topicShareLast12Months,
            leaderboardScopes: leaderboardScopes,
            leaderboardByTopic: leaderboardByTopic,
            leaderboardDefaultTopicId: leaderboardDefaultTopicId,
            themes: cachedThemes,
            aboutParagraph: (try? store.store.creatorAbout(channelId: channelId))?.summary,
            isClassifyingThemes: store.classifyingThemeChannels.contains(channelId),
            standoutEpisodesBySeriesLabel: makeStandoutEpisodes(themes: cachedThemes, allCards: scoredCards),
            monthlyVideoCounts: monthlyCounts,
            totalUploadsKnown: scoredCards.count,
            totalUploadsReported: totalUploadsReported,
            coveragePercent: coverage,
            channelCreatedDate: nil, // not yet sourced (Phase 3 channel-info enrichment)
            lastRefreshedAt: archive.compactMap(\.fetchedAt).compactMap(CreatorAnalytics.parseISO8601Date).max(),
            youtubeURL: youtubeURL,
            isFavorite: store.isCreatorFavorited(channelId),
            isExcluded: store.isExcludedCreator(channelId),
            notes: store.favoriteCreators.first(where: { $0.channelId == channelId })?.notes,
            newSinceLastVisitCount: newSinceCount,
            previousVisitDate: prevVisit
        )
    }

    /// Phase 3: read the favorite_channels.last_visited_at value (BEFORE bumping
    /// it for the current visit) and parse it. nil for non-favorited creators or
    /// rows with no prior visit. Used twice in the builder so it's a small helper.
    @MainActor
    private static func previousVisitDate(channelId: String, store: OrganizerStore) -> Date? {
        // try? on a throws -> String? function flattens to String?, so the
        // outer optional means "either the call threw or the column was null".
        guard let raw = (try? store.store.lastVisitedAt(channelId: channelId)) ?? nil else {
            return nil
        }
        return CreatorAnalytics.parseISO8601Date(raw)
    }

    /// Phase 3: count uploads (saved + archive merged into `allCards`) whose
    /// publishedAt is strictly after the previous visit timestamp. 0 when the
    /// cutoff is nil (first visit / non-favorited creator). Caller passes the
    /// cutoff so we don't read it twice from SQLite per page build.
    @MainActor
    private static func makeNewSinceLastVisitCount(
        cutoff: Date?,
        allCards: [CreatorVideoCard]
    ) -> Int {
        guard let cutoff else { return 0 }
        return allCards.reduce(0) { acc, card in
            guard let publishedAt = card.publishedAt,
                  let date = CreatorAnalytics.parseISO8601Date(publishedAt) else {
                return acc
            }
            return date > cutoff ? acc + 1 : acc
        }
    }

    // MARK: - Card construction

    private static func makeAllCards(
        savedByTopic: [(topic: TopicViewModel, videos: [VideoViewModel])],
        savedVideoIds: Set<String>,
        archive: [ArchivedChannelVideo]
    ) -> [CreatorVideoCard] {
        var cards: [CreatorVideoCard] = []
        cards.reserveCapacity(savedVideoIds.count + archive.count)

        for (topic, videos) in savedByTopic {
            for video in videos {
                cards.append(card(from: video, topicName: topic.name, topicId: topic.id))
            }
        }

        // Add archive videos that aren't already in the saved set.
        for archived in archive where !savedVideoIds.contains(archived.videoId) {
            cards.append(card(from: archived))
        }

        return cards
    }

    private static func card(from video: VideoViewModel, topicName: String?, topicId: Int64?) -> CreatorVideoCard {
        let parsedViews = video.viewCount.map { CreatorAnalytics.parseViewCount($0) } ?? 0
        let ageDays = video.publishedAt.map { CreatorAnalytics.parseAge($0) }
        let normalizedAge = (ageDays == .max) ? nil : ageDays
        return CreatorVideoCard(
            videoId: video.videoId,
            title: video.title,
            thumbnailUrl: video.thumbnailUrl,
            topicName: topicName,
            topicId: topicId,
            viewCountFormatted: video.viewCount ?? "—",
            viewCountParsed: parsedViews,
            runtimeFormatted: video.duration,
            publishedAt: video.publishedAt,
            ageDays: normalizedAge,
            ageFormatted: normalizedAge.map(CreatorAnalytics.formatAge),
            isSaved: true,
            outlierScore: 0,        // filled in by the outlier scoring pass
            isOutlier: false
        )
    }

    private static func card(from archived: ArchivedChannelVideo) -> CreatorVideoCard {
        let parsedViews = archived.viewCount.map { CreatorAnalytics.parseViewCount($0) } ?? 0
        let ageDays = archived.publishedAt.map { CreatorAnalytics.parseAge($0) }
        let normalizedAge = (ageDays == .max) ? nil : ageDays
        let thumb = URL(string: "https://i.ytimg.com/vi/\(archived.videoId)/mqdefault.jpg")
        return CreatorVideoCard(
            videoId: archived.videoId,
            title: archived.title,
            thumbnailUrl: thumb,
            topicName: nil,
            topicId: nil,
            viewCountFormatted: archived.viewCount ?? "—",
            viewCountParsed: parsedViews,
            runtimeFormatted: archived.duration,
            publishedAt: archived.publishedAt,
            ageDays: normalizedAge,
            ageFormatted: normalizedAge.map(CreatorAnalytics.formatAge),
            isSaved: false,
            outlierScore: 0,
            isOutlier: false
        )
    }

    // MARK: - Topic share

    /// Phase 3: filter the savedByTopic groupings to only include videos published
    /// in the last 365 days. Videos with no parseable publishedAt are dropped from
    /// the recent slice (we err on the side of "if we don't know when, we can't
    /// claim it's recent"). Topics that have no recent videos are dropped entirely.
    private static func filterSavedByTopicToRecentYear(
        _ savedByTopic: [(topic: TopicViewModel, videos: [VideoViewModel])]
    ) -> [(topic: TopicViewModel, videos: [VideoViewModel])] {
        let cutoff = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -365, to: Date()) ?? Date()
        return savedByTopic.compactMap { entry in
            let recentVideos = entry.videos.filter { video in
                guard let publishedAt = video.publishedAt,
                      let date = CreatorAnalytics.parseISO8601Date(publishedAt) else {
                    return false
                }
                return date >= cutoff
            }
            return recentVideos.isEmpty ? nil : (topic: entry.topic, videos: recentVideos)
        }
    }

    @MainActor
    private static func makeTopicShare(
        savedByTopic: [(topic: TopicViewModel, videos: [VideoViewModel])],
        store: OrganizerStore
    ) -> [CreatorTopicShare] {
        let total = savedByTopic.reduce(0) { $0 + $1.videos.count }
        guard total > 0 else { return [] }
        return savedByTopic
            .map { entry in
                let topicTotal = store.videosForTopicIncludingSubtopics(entry.topic.id).count
                let share = topicTotal > 0
                    ? Double(entry.videos.count) / Double(topicTotal)
                    : 0
                return CreatorTopicShare(
                    topicId: entry.topic.id,
                    topicName: entry.topic.name,
                    videoCount: entry.videos.count,
                    percentage: Double(entry.videos.count) / Double(total),
                    shareOfVoice: share,
                    topicTotalSavedCount: topicTotal
                )
            }
            .sorted { $0.videoCount > $1.videoCount }
    }

    // MARK: - Monthly cadence

    private static func makeMonthlyCounts(from cards: [CreatorVideoCard]) -> [CreatorMonthlyCount] {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        guard let twoYearsAgo = calendar.date(byAdding: .month, value: -23, to: now) else { return [] }
        let earliest = calendar.dateInterval(of: .month, for: twoYearsAgo)?.start ?? twoYearsAgo

        var bucket: [Date: Int] = [:]
        for card in cards {
            guard let publishedAt = card.publishedAt,
                  let date = CreatorAnalytics.parseISO8601Date(publishedAt) ?? approximateDate(forAgeDays: card.ageDays, now: now)
            else { continue }
            guard date >= earliest else { continue }
            guard let monthStart = calendar.dateInterval(of: .month, for: date)?.start else { continue }
            bucket[monthStart, default: 0] += 1
        }

        // Fill 24 buckets even when some are empty so the chart shape is stable.
        var result: [CreatorMonthlyCount] = []
        for offset in 0..<24 {
            guard let bucketStart = calendar.date(byAdding: .month, value: -offset, to: now)
                .flatMap({ calendar.dateInterval(of: .month, for: $0)?.start }) else { continue }
            result.append(CreatorMonthlyCount(month: bucketStart, count: bucket[bucketStart] ?? 0))
        }
        return result.sorted { $0.month < $1.month }
    }

    private static func approximateDate(forAgeDays ageDays: Int?, now: Date) -> Date? {
        guard let ageDays else { return nil }
        return Calendar.current.date(byAdding: .day, value: -ageDays, to: now)
    }

    // MARK: - Playlists

    /// Phase 3: for each series-typed theme cluster, find the standout episode by
    /// scoring videos against the SERIES median (not the channel median). Returns a
    /// map of `seriesLabel → standoutVideoId`. The standout is the video with the
    /// highest series-scoped outlier score; if no video meaningfully exceeds the
    /// series median (max ratio < 1.5×), the series gets no standout.
    ///
    /// Costs nothing — pure stats over the existing `OutlierAnalytics` module on
    /// data already in memory. The series detection itself happens upstream in the
    /// LLM theme classifier (Phase 2 #4); this function just consumes its output.
    private static func makeStandoutEpisodes(
        themes: [CreatorThemeRecord],
        allCards: [CreatorVideoCard]
    ) -> [String: String] {
        guard !themes.isEmpty else { return [:] }
        let cardsById = Dictionary(uniqueKeysWithValues: allCards.map { ($0.videoId, $0) })

        var result: [String: String] = [:]
        for theme in themes where theme.isSeries {
            let seriesCards = theme.videoIds.compactMap { cardsById[$0] }
            guard seriesCards.count >= 3 else { continue } // not enough to compute a meaningful median

            let seriesMedian = OutlierAnalytics.channelMedianViews(seriesCards)
            guard seriesMedian > 0 else { continue }

            // Find the video with the highest views relative to the series median.
            // Require at least 1.5× to count as a "standout" — anything less is just
            // normal variance within the series.
            var bestRatio: Double = 0
            var bestVideoId: String?
            for card in seriesCards where card.viewCountParsed > 0 {
                let ratio = Double(card.viewCountParsed) / Double(seriesMedian)
                if ratio > bestRatio {
                    bestRatio = ratio
                    bestVideoId = card.videoId
                }
            }
            if let bestVideoId, bestRatio >= 1.5 {
                result[theme.label] = bestVideoId
            }
        }
        return result
    }

    /// Returns the eligible scope topics for the leaderboard picker — every topic
    /// the page creator publishes in. Each scope tracks how many distinct creators
    /// publish in that topic so the picker can show "Mech Kbds (12 creators)".
    @MainActor
    private static func makeLeaderboardScopes(
        forChannelId channelId: String,
        in store: OrganizerStore
    ) -> [CreatorLeaderboardScope] {
        let topicLookup = Dictionary(uniqueKeysWithValues: store.topics.map { ($0.id, $0.name) })
        let scopes = store.topicChannels
            .compactMap { topicId, channels -> CreatorLeaderboardScope? in
                guard channels.contains(where: { $0.channelId == channelId }) else { return nil }
                let topicName = topicLookup[topicId] ?? "Unknown"
                let creatorIds = Set(channels.map(\.channelId))
                return CreatorLeaderboardScope(
                    topicId: topicId,
                    topicName: topicName,
                    creatorCount: creatorIds.count
                )
            }
            .sorted { $0.topicName.localizedStandardCompare($1.topicName) == .orderedAscending }
        return scopes
    }

    /// Default scope = the topic with the most of the page creator's saved videos
    /// (their primary topic). nil when the creator has no topics.
    private static func makeLeaderboardDefaultTopicId(
        forChannelId channelId: String,
        savedByTopic: [(topic: TopicViewModel, videos: [VideoViewModel])]
    ) -> Int64? {
        savedByTopic
            .max(by: { $0.videos.count < $1.videos.count })?
            .topic.id
    }

    /// Builds the per-topic dominance leaderboard. For each topic the page creator
    /// publishes in, computes the top 10 creators in that topic with three pre-computed
    /// metrics: saved count, outlier count, total views. The view picks one topic +
    /// one metric and sorts the entries on the fly — switching is instant because all
    /// three numbers are stored on the entry.
    ///
    /// Per the plan (Appendix B): the framing is *library-scoped dominance*, not
    /// global subscriber count. We rank by what the user has actually saved and how
    /// videos in that topic perform — not by external follower counts that don't
    /// answer "who's doing the work in this niche."
    ///
    /// Outlier count uses the Phase 1 OutlierAnalytics primitive against each
    /// creator's CHANNEL median (not the topic median), so an outlier is "this video
    /// punched above this creator's normal performance," consistent with the rest of
    /// the app.
    @MainActor
    private static func makeLeaderboardByTopic(
        forChannelId channelId: String,
        in store: OrganizerStore
    ) -> [Int64: [CreatorLeaderboardEntry]] {
        // Find topics the page creator publishes in.
        let scopeTopicIds = store.topicChannels
            .filter { _, channels in channels.contains { $0.channelId == channelId } }
            .map { $0.key }
        guard !scopeTopicIds.isEmpty else { return [:] }

        // Pre-compute each candidate creator's channel median, cached so we don't
        // walk their full video list repeatedly. Built lazily as we encounter
        // creators across the scope topics.
        var medianCache: [String: Int] = [:]

        var result: [Int64: [CreatorLeaderboardEntry]] = [:]
        for topicId in scopeTopicIds {
            let topicVideos = store.videosForTopicIncludingSubtopics(topicId)

            // Group this topic's videos by channelId so we have one bucket per creator.
            var byCreator: [String: [VideoViewModel]] = [:]
            for video in topicVideos {
                guard let cid = video.channelId, !cid.isEmpty else { continue }
                byCreator[cid, default: []].append(video)
            }

            var entries: [CreatorLeaderboardEntry] = []
            for (creatorId, videosInTopic) in byCreator {
                guard let record = store.topicChannels[topicId]?.first(where: { $0.channelId == creatorId }) else {
                    continue
                }

                // Lazily compute the channel median across ALL their known videos
                // (across every topic the user has saved them in).
                let channelMedian: Int
                if let cached = medianCache[creatorId] {
                    channelMedian = cached
                } else {
                    let allVideos = store.topics
                        .flatMap { store.videosForTopicIncludingSubtopics($0.id) }
                        .filter { $0.channelId == creatorId }
                    let proxies = allVideos.map { LeaderboardOutlierProxy(video: $0) }
                    channelMedian = OutlierAnalytics.channelMedianViews(proxies)
                    medianCache[creatorId] = channelMedian
                }

                // Three metrics for THIS topic only.
                let savedCount = videosInTopic.count

                let outlierCount: Int
                let totalViewsInTopic: Int
                if channelMedian > 0 {
                    var outlierTally = 0
                    var viewSum = 0
                    for video in videosInTopic {
                        let parsedViews = video.viewCount.map { CreatorAnalytics.parseViewCount($0) } ?? 0
                        viewSum += parsedViews
                        if parsedViews >= channelMedian * Int(OutlierAnalytics.defaultOutlierThreshold) {
                            outlierTally += 1
                        }
                    }
                    outlierCount = outlierTally
                    totalViewsInTopic = viewSum
                } else {
                    outlierCount = 0
                    totalViewsInTopic = videosInTopic.reduce(0) { acc, v in
                        acc + (v.viewCount.map { CreatorAnalytics.parseViewCount($0) } ?? 0)
                    }
                }

                entries.append(CreatorLeaderboardEntry(
                    channelId: creatorId,
                    channelName: record.name,
                    channelIconUrl: record.iconUrl
                        .map(upscaledAvatarURL)
                        .flatMap(URL.init(string:)),
                    savedVideoCount: savedCount,
                    outlierVideoCount: outlierCount,
                    totalViewsInTopic: totalViewsInTopic,
                    subscriberCountFormatted: formatSubscriberCount(record.subscriberCount),
                    isPageCreator: creatorId == channelId
                ))
            }

            // Sort by saved video count desc as the default storage order; the view
            // re-sorts in-place on the (small) array when the user picks a different
            // metric, so storage order is just a sensible default.
            let sorted = entries.sorted { lhs, rhs in
                if lhs.savedVideoCount != rhs.savedVideoCount {
                    return lhs.savedVideoCount > rhs.savedVideoCount
                }
                return lhs.channelName.localizedStandardCompare(rhs.channelName) == .orderedAscending
            }
            result[topicId] = Array(sorted.prefix(10))
        }
        return result
    }
}

/// Tiny adapter so OutlierAnalytics.channelMedianViews can consume VideoViewModel.
private struct LeaderboardOutlierProxy: OutlierAnalyzable {
    let video: VideoViewModel
    var outlierViewCount: Int? {
        let parsed = video.viewCount.map { CreatorAnalytics.parseViewCount($0) } ?? 0
        return parsed > 0 ? parsed : nil
    }
    var outlierAgeDays: Int? {
        video.publishedAt.map { CreatorAnalytics.parseAge($0) }
    }
}

/// Continuation of CreatorPageBuilder helpers. The leaderboard helpers above
/// closed the main enum scope; the remaining helpers (playlists, topic share,
/// monthly cadence, etc.) live in this extension.
extension CreatorPageBuilder {

    @MainActor
    private static func makePlaylists(
        savedVideos: [VideoViewModel],
        store: OrganizerStore
    ) -> [CreatorPlaylistEntry] {
        var byPlaylistId: [String: (playlist: PlaylistRecord, count: Int)] = [:]
        for video in savedVideos {
            let memberships = store.playlistsForVideo(video.videoId)
            for playlist in memberships {
                byPlaylistId[playlist.playlistId, default: (playlist, 0)].count += 1
            }
        }
        return byPlaylistId.values
            .map { CreatorPlaylistEntry(playlist: $0.playlist, creatorVideoCount: $0.count) }
            .sorted { lhs, rhs in
                if lhs.creatorVideoCount != rhs.creatorVideoCount {
                    return lhs.creatorVideoCount > rhs.creatorVideoCount
                }
                return lhs.playlist.title.localizedStandardCompare(rhs.playlist.title) == .orderedAscending
            }
    }

    // MARK: - Subtitle / tier helpers

    private static func makeSubtitle(from channel: ChannelRecord?) -> String? {
        guard let description = channel?.description, !description.isEmpty else { return nil }
        // Take the first sentence (or the full description if there's no sentence break)
        // and let the SwiftUI view handle visual truncation via .lineLimit + .truncationMode.
        // Hard-capping the string here was the bug — it chopped mid-word with no ellipsis.
        let separators = CharacterSet(charactersIn: ".!?\n")
        let firstSentence = description
            .components(separatedBy: separators)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? description
        let trimmed = firstSentence.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func creatorTier(from subscriberString: String?) -> String? {
        guard let subs = subscriberString.flatMap(Int.init) else { return nil }
        if subs >= 10_000_000 { return "mega creator" }
        if subs >= 1_000_000 { return "large creator" }
        if subs >= 100_000 { return "mid-tier creator" }
        if subs >= 10_000 { return "growing creator" }
        return "small creator"
    }

    private static func formatSubscriberCount(_ raw: String?) -> String? {
        guard let subs = raw.flatMap(Int.init) else { return nil }
        if subs >= 1_000_000 {
            return String(format: "%.1fM subs", Double(subs) / 1_000_000)
        }
        if subs >= 1_000 {
            return String(format: "%.0fK subs", Double(subs) / 1_000)
        }
        return "\(subs) subs"
    }

    private static func formatViewTotal(_ totalViews: Int) -> String {
        if totalViews >= 1_000_000 {
            return String(format: "%.1fM views", Double(totalViews) / 1_000_000)
        }
        if totalViews >= 1_000 {
            return String(format: "%.0fK views", Double(totalViews) / 1_000)
        }
        return "\(totalViews) views"
    }

    /// Rewrite a YouTube channel avatar URL to request a larger image. YouTube serves
    /// avatars from `yt3.ggpht.com` (and a few related hosts) with a `=sNNN` size
    /// parameter in the URL path — `=s88`, `=s240`, etc. The same image is available
    /// at any size by changing that number, with no scraping or new requests required.
    /// We bump everything to `=s800` for the creator detail page header (rendered at
    /// 160pt × 2x retina = 320px effective; 800px gives plenty of headroom).
    ///
    /// Non-yt3 URLs and URLs without a size parameter are returned unchanged.
    static func upscaledAvatarURL(_ urlString: String) -> String {
        guard urlString.contains("ggpht.com") || urlString.contains("googleusercontent.com") else {
            return urlString
        }
        let pattern = #"=s\d+"#
        return urlString.replacingOccurrences(
            of: pattern,
            with: "=s800",
            options: .regularExpression
        )
    }

    private static func computeFoundingYear(from cards: [CreatorVideoCard]) -> Int? {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let oldestDate = cards.compactMap { card -> Date? in
            if let published = card.publishedAt, let date = CreatorAnalytics.parseISO8601Date(published) {
                return date
            }
            if let ageDays = card.ageDays {
                return calendar.date(byAdding: .day, value: -ageDays, to: now)
            }
            return nil
        }.min()
        return oldestDate.map { calendar.component(.year, from: $0) }
    }
}
