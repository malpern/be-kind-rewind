import Foundation

/// Anything we can score for "punching above the channel baseline" must expose at minimum a
/// parsed view count and an age in days. Both are optional because scrape data is fuzzy and
/// some sources (RSS fallback) leave fields nil. Conformances for the app's existing video
/// types live in their own files alongside the type definitions.
protocol OutlierAnalyzable {
    /// Best-effort view count for outlier scoring. `nil` when unknown.
    var outlierViewCount: Int? { get }
    /// Days since publish for recency weighting. `nil` is treated as "very old".
    var outlierAgeDays: Int? { get }
}

/// Pure functions for ranking videos by how far they punch above their channel's baseline.
///
/// This is the cross-cutting analysis primitive shared across the entire creator detail
/// page plan and beyond. It is intentionally tiny, has no UI dependencies, and operates on
/// arrays of values via the `OutlierAnalyzable` protocol so consumers can adapt their own
/// types without coupling to a specific video model.
///
/// The math is deliberately simple:
///   `outlierScore(v) = v.views / channelMedianViews`
///
/// A video with `outlierScore >= defaultOutlierThreshold` (3.0 by default) is considered an
/// outlier — it received at least 3× the channel's median views. The framing comes from
/// the YouTube research-tools category (vidIQ, 1of10, TubeBuddy, Morningfame), where this
/// metric is the most-cited primitive for surfacing "videos that punched above the
/// creator's normal performance" rather than just "the biggest channels overall".
///
/// See `docs/creator-detail-page-plan.md` Appendix D for the research that informed this.
enum OutlierAnalytics {

    // MARK: - Tunables

    /// Below this many known view counts, the median is statistically meaningless and we
    /// fall back to the arithmetic mean. Eight is roughly where the median becomes useful.
    static let minSampleForMedian: Int = 6

    /// Default threshold for `isOutlier`: a video must receive at least 3× the channel's
    /// median view count to be flagged as an outlier.
    static let defaultOutlierThreshold: Double = 3.0

    /// Cap on a single video's outlier score so one freak hit cannot dominate sorting.
    /// Without this, a 100×-baseline viral video would crowd out everything else in
    /// `topOutliers`. The cap matches the upper end of 1of10's typical "10×-100×" framing.
    static let maxOutlierScore: Double = 50.0

    // MARK: - Median computation

    /// Median view count across all known videos for a creator (or any other grouping).
    ///
    /// Returns 0 when the input has no positive view counts. Falls back to the arithmetic
    /// mean when the sample size is below `minSampleForMedian` because the median is not
    /// robust at small N. Ignores nil and zero view counts.
    static func channelMedianViews<T: OutlierAnalyzable>(_ videos: [T]) -> Int {
        let counts = videos.compactMap(\.outlierViewCount).filter { $0 > 0 }
        guard !counts.isEmpty else { return 0 }

        if counts.count < minSampleForMedian {
            let total = counts.reduce(0, +)
            return total / counts.count
        }

        let sorted = counts.sorted()
        if sorted.count.isMultiple(of: 2) {
            let lower = sorted[(sorted.count / 2) - 1]
            let upper = sorted[sorted.count / 2]
            return (lower + upper) / 2
        }
        return sorted[sorted.count / 2]
    }

    // MARK: - Per-video scoring

    /// Outlier score for a single video relative to a channel's median view count.
    ///
    /// - Returns 0 when either the view count or the channel median is missing or zero.
    /// - Capped at `maxOutlierScore` so freak hits cannot dominate.
    /// - The result is dimensionless: `1.0` means the video matches the median exactly,
    ///   `2.5` means it received 2.5× the median, etc.
    static func outlierScore(views: Int?, channelMedian: Int) -> Double {
        guard let views, views > 0, channelMedian > 0 else { return 0 }
        let raw = Double(views) / Double(channelMedian)
        return min(raw, maxOutlierScore)
    }

    /// Convenience: returns true if the video's outlier score meets or exceeds the threshold.
    /// Defaults to `defaultOutlierThreshold` (3.0).
    static func isOutlier<T: OutlierAnalyzable>(
        _ video: T,
        channelMedian: Int,
        threshold: Double = defaultOutlierThreshold
    ) -> Bool {
        outlierScore(views: video.outlierViewCount, channelMedian: channelMedian) >= threshold
    }

    // MARK: - Recency weighting

    /// Multiplier applied during top-N selection so stale viral hits do not dominate the
    /// curated list forever. Returns 1.0 for the last year, decaying gradually after.
    /// Videos with unknown age are treated as "old" (0.5).
    static func recencyWeight(ageDays: Int?) -> Double {
        guard let ageDays else { return 0.5 }
        if ageDays <= 365 { return 1.0 }
        if ageDays <= 730 { return 0.75 }
        return 0.5
    }

    // MARK: - Top-N selection

    /// Returns the top N videos ranked by `outlierScore × recencyWeight`. Tiebreaker:
    /// raw view count.
    ///
    /// - When the channel median is 0 (no usable view counts at all), falls back to a
    ///   plain raw-view-count sort so the caller still gets a non-empty list when possible.
    /// - Videos with no parsed view count are excluded entirely — they cannot be ranked.
    /// - The cap of `limit` is applied after sorting.
    static func topOutliers<T: OutlierAnalyzable>(
        _ videos: [T],
        limit: Int = 8
    ) -> [T] {
        guard !videos.isEmpty else { return [] }

        let median = channelMedianViews(videos)
        guard median > 0 else {
            return videos
                .filter { ($0.outlierViewCount ?? 0) > 0 }
                .sorted { ($0.outlierViewCount ?? 0) > ($1.outlierViewCount ?? 0) }
                .prefix(limit)
                .map { $0 }
        }

        let scored = videos
            .map { (video: $0, score: weightedScore(for: $0, channelMedian: median)) }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return (lhs.video.outlierViewCount ?? 0) > (rhs.video.outlierViewCount ?? 0)
            }

        return scored.prefix(limit).map(\.video)
    }

    // MARK: - Internal helpers

    private static func weightedScore<T: OutlierAnalyzable>(
        for video: T,
        channelMedian: Int
    ) -> Double {
        let raw = outlierScore(views: video.outlierViewCount, channelMedian: channelMedian)
        return raw * recencyWeight(ageDays: video.outlierAgeDays)
    }
}
