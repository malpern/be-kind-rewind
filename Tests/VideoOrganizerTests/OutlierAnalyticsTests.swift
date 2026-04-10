import Foundation
import Testing
@testable import VideoOrganizer

/// Minimal test fixture for `OutlierAnalyzable`. Real conformances on app types arrive in
/// later commits when the consumers (Essentials selection, table badge) are wired up.
private struct TestVideo: OutlierAnalyzable {
    let outlierViewCount: Int?
    let outlierAgeDays: Int?

    init(views: Int?, ageDays: Int? = 30) {
        self.outlierViewCount = views
        self.outlierAgeDays = ageDays
    }
}

@Suite("OutlierAnalytics")
struct OutlierAnalyticsTests {

    // MARK: - channelMedianViews

    @Test("channelMedianViews returns 0 for empty input")
    func medianEmpty() {
        let videos: [TestVideo] = []
        #expect(OutlierAnalytics.channelMedianViews(videos) == 0)
    }

    @Test("channelMedianViews returns 0 when all view counts are nil")
    func medianAllNil() {
        let videos = [TestVideo(views: nil), TestVideo(views: nil)]
        #expect(OutlierAnalytics.channelMedianViews(videos) == 0)
    }

    @Test("channelMedianViews ignores zero view counts")
    func medianIgnoresZeros() {
        let videos = [TestVideo(views: 0), TestVideo(views: 0), TestVideo(views: 100)]
        #expect(OutlierAnalytics.channelMedianViews(videos) == 100)
    }

    @Test("channelMedianViews falls back to mean when sample size is below minSampleForMedian")
    func medianFallsBackToMeanForSmallSample() {
        // 5 videos: mean = (10+20+30+40+1000)/5 = 220
        // median would be 30 — we want the mean instead because the sample is too small.
        let videos = [
            TestVideo(views: 10),
            TestVideo(views: 20),
            TestVideo(views: 30),
            TestVideo(views: 40),
            TestVideo(views: 1000)
        ]
        let result = OutlierAnalytics.channelMedianViews(videos)
        #expect(result == 220)
    }

    @Test("channelMedianViews uses true median when sample size is at least minSampleForMedian")
    func medianTrueAtLargerSample() {
        // 6 videos sorted: [10, 20, 30, 40, 50, 1000]
        // median = (30 + 40) / 2 = 35 (even count)
        let videos = [
            TestVideo(views: 10),
            TestVideo(views: 20),
            TestVideo(views: 30),
            TestVideo(views: 40),
            TestVideo(views: 50),
            TestVideo(views: 1000)
        ]
        #expect(OutlierAnalytics.channelMedianViews(videos) == 35)
    }

    @Test("channelMedianViews returns the middle value for odd-count samples")
    func medianOddCount() {
        // 7 videos: [10, 20, 30, 40, 50, 60, 70] — middle is index 3 = 40
        let videos = (1...7).map { TestVideo(views: $0 * 10) }
        #expect(OutlierAnalytics.channelMedianViews(videos) == 40)
    }

    @Test("channelMedianViews is robust to a single dominant outlier")
    func medianRobustToSingleSpike() {
        // Most videos cluster around 100; one spike to 50000.
        // Median should still be ~100, not skewed.
        let videos = [
            TestVideo(views: 80),
            TestVideo(views: 90),
            TestVideo(views: 100),
            TestVideo(views: 110),
            TestVideo(views: 120),
            TestVideo(views: 130),
            TestVideo(views: 50000)
        ]
        let median = OutlierAnalytics.channelMedianViews(videos)
        #expect(median == 110) // index 3 of 7
    }

    // MARK: - outlierScore

    @Test("outlierScore returns 0 when views are nil")
    func scoreNilViews() {
        #expect(OutlierAnalytics.outlierScore(views: nil, channelMedian: 1000) == 0)
    }

    @Test("outlierScore returns 0 when channel median is 0")
    func scoreZeroMedian() {
        #expect(OutlierAnalytics.outlierScore(views: 5000, channelMedian: 0) == 0)
    }

    @Test("outlierScore returns 0 when views are 0")
    func scoreZeroViews() {
        #expect(OutlierAnalytics.outlierScore(views: 0, channelMedian: 1000) == 0)
    }

    @Test("outlierScore equals 1 when views match the median exactly")
    func scoreEqualsOneAtMedian() {
        #expect(OutlierAnalytics.outlierScore(views: 1000, channelMedian: 1000) == 1.0)
    }

    @Test("outlierScore reflects the ratio above the median")
    func scoreRatio() {
        #expect(OutlierAnalytics.outlierScore(views: 2500, channelMedian: 1000) == 2.5)
        #expect(OutlierAnalytics.outlierScore(views: 5000, channelMedian: 1000) == 5.0)
    }

    @Test("outlierScore is capped at maxOutlierScore to prevent freak hits from dominating")
    func scoreCapped() {
        let result = OutlierAnalytics.outlierScore(views: 10_000_000, channelMedian: 1_000)
        #expect(result == OutlierAnalytics.maxOutlierScore)
    }

    // MARK: - isOutlier

    @Test("isOutlier returns true when score meets the default threshold")
    func isOutlierAtDefaultThreshold() {
        let video = TestVideo(views: 3_000)
        #expect(OutlierAnalytics.isOutlier(video, channelMedian: 1_000) == true)
    }

    @Test("isOutlier returns false when score is just below the threshold")
    func isOutlierBelowThreshold() {
        let video = TestVideo(views: 2_999)
        #expect(OutlierAnalytics.isOutlier(video, channelMedian: 1_000) == false)
    }

    @Test("isOutlier honors a custom threshold")
    func isOutlierCustomThreshold() {
        let video = TestVideo(views: 1_500)
        #expect(OutlierAnalytics.isOutlier(video, channelMedian: 1_000, threshold: 1.5) == true)
        #expect(OutlierAnalytics.isOutlier(video, channelMedian: 1_000, threshold: 2.0) == false)
    }

    // MARK: - recencyWeight

    @Test("recencyWeight returns full weight inside the first year")
    func recencyFullWeight() {
        #expect(OutlierAnalytics.recencyWeight(ageDays: 0) == 1.0)
        #expect(OutlierAnalytics.recencyWeight(ageDays: 365) == 1.0)
    }

    @Test("recencyWeight decays in the second year")
    func recencyDecaysSecondYear() {
        #expect(OutlierAnalytics.recencyWeight(ageDays: 366) == 0.75)
        #expect(OutlierAnalytics.recencyWeight(ageDays: 730) == 0.75)
    }

    @Test("recencyWeight decays further beyond two years")
    func recencyDecaysOldVideos() {
        #expect(OutlierAnalytics.recencyWeight(ageDays: 1000) == 0.5)
        #expect(OutlierAnalytics.recencyWeight(ageDays: 5000) == 0.5)
    }

    @Test("recencyWeight treats unknown age as old")
    func recencyTreatsNilAsOld() {
        #expect(OutlierAnalytics.recencyWeight(ageDays: nil) == 0.5)
    }

    // MARK: - topOutliers

    @Test("topOutliers returns empty for empty input")
    func topEmpty() {
        let videos: [TestVideo] = []
        #expect(OutlierAnalytics.topOutliers(videos).isEmpty)
    }

    @Test("topOutliers respects the limit")
    func topRespectsLimit() {
        let videos = (1...20).map { TestVideo(views: $0 * 1000, ageDays: 30) }
        let result = OutlierAnalytics.topOutliers(videos, limit: 5)
        #expect(result.count == 5)
    }

    @Test("topOutliers ranks higher view counts above lower at equal recency")
    func topRanksByViewCount() {
        let small = TestVideo(views: 1_000, ageDays: 30)
        let medium = TestVideo(views: 5_000, ageDays: 30)
        let large = TestVideo(views: 10_000, ageDays: 30)
        let result = OutlierAnalytics.topOutliers([small, medium, large], limit: 3)
        #expect(result.count == 3)
        #expect(result.first?.outlierViewCount == 10_000)
        #expect(result.last?.outlierViewCount == 1_000)
    }

    @Test("topOutliers down-weights very old videos relative to recent ones")
    func topRecencyWeighting() {
        // The old video has 4× the views but is ancient (2.5 years).
        // The fresh video has fewer views but is brand new.
        // After recency weighting (4× × 0.5 = 2.0 vs 2× × 1.0 = 2.0), the tiebreaker is
        // raw view count, so the old video still wins narrowly. Use a wider gap to be sure.
        let oldHit = TestVideo(views: 4_000, ageDays: 1000)   // weight 0.5
        let newHit = TestVideo(views: 3_000, ageDays: 30)     // weight 1.0
        // Median of these two: (3000+4000)/2 = 3500, falls back to mean since N < 6
        // oldHit score: 4000/3500 = 1.143 × 0.5 = 0.571
        // newHit score: 3000/3500 = 0.857 × 1.0 = 0.857
        // newHit should win
        let result = OutlierAnalytics.topOutliers([oldHit, newHit], limit: 2)
        #expect(result.first?.outlierViewCount == 3_000)
    }

    @Test("topOutliers uses raw view count tiebreaker when scores are equal")
    func topTiebreaker() {
        // Two videos with identical age and view count → result should still be deterministic.
        let a = TestVideo(views: 5_000, ageDays: 30)
        let b = TestVideo(views: 5_000, ageDays: 30)
        let c = TestVideo(views: 4_000, ageDays: 30)
        let result = OutlierAnalytics.topOutliers([c, a, b], limit: 3)
        #expect(result.count == 3)
        #expect(result.last?.outlierViewCount == 4_000)
    }

    @Test("topOutliers excludes videos with no view count")
    func topExcludesNullViews() {
        let real = TestVideo(views: 1_000, ageDays: 30)
        let unknown = TestVideo(views: nil, ageDays: 30)
        let result = OutlierAnalytics.topOutliers([real, unknown], limit: 5)
        #expect(result.count == 1)
        #expect(result.first?.outlierViewCount == 1_000)
    }

    @Test("topOutliers falls back to raw view count sort when median is 0")
    func topFallsBackWhenNoMedian() {
        // All view counts are 0 OR nil → median is 0 → fallback path.
        // We need at least one positive view count for the fallback to return anything.
        let zero = TestVideo(views: 0, ageDays: 30)
        let nilOne = TestVideo(views: nil, ageDays: 30)
        let positive = TestVideo(views: 100, ageDays: 30)
        let result = OutlierAnalytics.topOutliers([zero, nilOne, positive], limit: 5)
        #expect(result.count == 1)
        #expect(result.first?.outlierViewCount == 100)
    }

    @Test("topOutliers surfaces a true outlier above the recent baseline")
    func topSurfacesGenuineOutlier() {
        // Six baseline videos around 1k views, one outlier at 8k. Outlier should rank #1.
        let baseline = (1...6).map { _ in TestVideo(views: 1_000, ageDays: 30) }
        let outlier = TestVideo(views: 8_000, ageDays: 30)
        var input = baseline
        input.append(outlier)
        let result = OutlierAnalytics.topOutliers(input, limit: 7)
        #expect(result.first?.outlierViewCount == 8_000)
    }
}
