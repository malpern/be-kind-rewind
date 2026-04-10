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

    // Top creators in this niche — other creators in the user's library who publish
    // in topics that overlap with this creator's. Ranked by saved video count by
    // default. Excludes self. Capped at 10. Empty when this creator only appears
    // in topics where no one else has videos.
    let leaderboardEntries: [CreatorLeaderboardEntry]

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
        leaderboardEntries: [CreatorLeaderboardEntry],
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
        notes: String?
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
        self.leaderboardEntries = leaderboardEntries
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
        leaderboardEntries: [],
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

struct CreatorLeaderboardEntry: Identifiable, Equatable {
    let channelId: String
    let channelName: String
    let channelIconUrl: URL?
    /// Number of topics this creator shares with the page's creator (1+).
    let sharedTopicCount: Int
    /// Total saved videos this creator has in shared topics. Kept as a secondary
    /// signal — exposes the bias toward what the user happens to have saved.
    let savedVideoCount: Int
    /// Parsed subscriber count from the channel record. The PRIMARY ranking signal —
    /// it's the most honest "niche dominance" proxy because it's external to the
    /// user's library and reflects what the rest of YouTube has voted on with their
    /// subscriptions. nil only when the channel record is missing it.
    let subscriberCount: Int?
    /// Subscriber count formatted for display ("1.2M", "410K", "9K").
    let subscriberCountFormatted: String?
    /// True for the row representing the creator whose page is currently shown.
    /// The leaderboard renders this row with a highlight so the user can see where
    /// the page creator sits in the ranking, not just who else is in the niche.
    let isPageCreator: Bool

    var id: String { channelId }
}

// MARK: - Builder

enum CreatorPageBuilder {
    /// Builds a fully-populated creator page model from data already in memory.
    /// All inputs come from the `OrganizerStore` cache — no async, no I/O.
    @MainActor
    static func makePage(forChannelId channelId: String, in store: OrganizerStore) -> CreatorPageViewModel {
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
        let topicShare = makeTopicShare(savedByTopic: savedByTopic, store: store)

        // 13. Monthly cadence (last 24 months) — use parseISO8601 dates from publishedAt.
        let monthlyCounts = makeMonthlyCounts(from: scoredCards)

        // 14. Playlists this creator's videos appear in.
        let playlists = makePlaylists(savedVideos: savedVideosFlat, store: store)

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
            leaderboardEntries: makeLeaderboard(forChannelId: channelId, in: store),
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
            notes: store.favoriteCreators.first(where: { $0.channelId == channelId })?.notes
        )
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

    /// Builds the niche dominance leaderboard — every creator in the user's library
    /// who publishes in topics that overlap with the page creator, INCLUDING the page
    /// creator themselves so the user can see where they sit in the ranking.
    ///
    /// Ranking signal: **subscriber count**. This is the most honest "niche dominance"
    /// proxy because it's external to the user's library — it reflects what the rest
    /// of YouTube has voted on with their subscriptions, not what the user happens to
    /// have saved. The earlier version ranked by saved video count, which was biased
    /// toward whatever the user had bothered to save and didn't actually answer "who
    /// dominates this niche".
    ///
    /// Algorithm:
    /// 1. Find every topic the page creator appears in (their topic footprint).
    /// 2. For each shared topic, gather every channelId that also appears there.
    ///    Self is INCLUDED in the result so we can highlight where they sit.
    /// 3. For each candidate, count their videos in shared topics (secondary signal)
    ///    and resolve their subscriber count from the channel record.
    /// 4. Rank by parsed subscriber count desc. Tiebreaker by saved video count desc,
    ///    then by name. Creators with no subscriber count sort last.
    /// 5. Return top 10.
    @MainActor
    private static func makeLeaderboard(
        forChannelId channelId: String,
        in store: OrganizerStore
    ) -> [CreatorLeaderboardEntry] {
        // Step 1: find topics this creator publishes in.
        let sharedTopicIds = store.topicChannels
            .filter { _, channels in channels.contains { $0.channelId == channelId } }
            .map { $0.key }

        guard !sharedTopicIds.isEmpty else { return [] }

        // Step 2-3: tally creators (including self) by video count across shared topics.
        var tally: [String: (sharedTopicCount: Int, savedVideoCount: Int, record: ChannelRecord)] = [:]

        for topicId in sharedTopicIds {
            let topicVideos = store.videosForTopicIncludingSubtopics(topicId)
            var perChannelInTopic: [String: Int] = [:]
            for video in topicVideos {
                guard let cid = video.channelId, !cid.isEmpty else { continue }
                perChannelInTopic[cid, default: 0] += 1
            }

            for (cid, countInTopic) in perChannelInTopic {
                guard let record = store.topicChannels[topicId]?.first(where: { $0.channelId == cid }) else {
                    continue
                }
                if var existing = tally[cid] {
                    existing.sharedTopicCount += 1
                    existing.savedVideoCount += countInTopic
                    tally[cid] = existing
                } else {
                    tally[cid] = (sharedTopicCount: 1, savedVideoCount: countInTopic, record: record)
                }
            }
        }

        // Step 4-5: rank by subscriber count, build entries.
        let entries = tally.values
            .map { entry -> CreatorLeaderboardEntry in
                let subs = parseSubscriberCount(entry.record.subscriberCount)
                return CreatorLeaderboardEntry(
                    channelId: entry.record.channelId,
                    channelName: entry.record.name,
                    channelIconUrl: entry.record.iconUrl
                        .map(upscaledAvatarURL)
                        .flatMap(URL.init(string:)),
                    sharedTopicCount: entry.sharedTopicCount,
                    savedVideoCount: entry.savedVideoCount,
                    subscriberCount: subs,
                    subscriberCountFormatted: formatSubscriberCount(entry.record.subscriberCount),
                    isPageCreator: entry.record.channelId == channelId
                )
            }
            .sorted { lhs, rhs in
                // Subscriber count is the primary signal. nil sorts last.
                switch (lhs.subscriberCount, rhs.subscriberCount) {
                case let (l?, r?) where l != r:
                    return l > r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
                // Tiebreakers: saved video count desc, then name asc.
                if lhs.savedVideoCount != rhs.savedVideoCount {
                    return lhs.savedVideoCount > rhs.savedVideoCount
                }
                return lhs.channelName.localizedStandardCompare(rhs.channelName) == .orderedAscending
            }

        return Array(entries.prefix(10))
    }

    /// Parse the channel record's subscriber count string ("1200000", "150000") to Int.
    /// Returns nil for empty / unparseable / negative values. Strict parsing only —
    /// no "1.2M" handling needed since the YouTube API returns raw integer strings.
    private static func parseSubscriberCount(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), value > 0 else { return nil }
        return value
    }

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
