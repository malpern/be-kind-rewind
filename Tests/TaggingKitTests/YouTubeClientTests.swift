import Foundation
import Testing
@testable import TaggingKit

@Suite("YouTubeClient")
struct YouTubeClientTests {
    @Test("formats view counts for raw values")
    func formattedViewCount() {
        #expect(VideoMetadata(videoId: "a", viewCount: nil, publishedAt: nil, duration: nil, channelId: nil, channelTitle: nil).formattedViewCount == nil)
        #expect(VideoMetadata(videoId: "a", viewCount: "999", publishedAt: nil, duration: nil, channelId: nil, channelTitle: nil).formattedViewCount == "999 views")
        #expect(VideoMetadata(videoId: "a", viewCount: "340000", publishedAt: nil, duration: nil, channelId: nil, channelTitle: nil).formattedViewCount == "340K views")
        #expect(VideoMetadata(videoId: "a", viewCount: "1200000", publishedAt: nil, duration: nil, channelId: nil, channelTitle: nil).formattedViewCount == "1.2M views")
    }

    @Test("formats ISO 8601 durations")
    func formattedDuration() {
        #expect(VideoMetadata(videoId: "a", viewCount: nil, publishedAt: nil, duration: nil, channelId: nil, channelTitle: nil).formattedDuration == nil)
        #expect(VideoMetadata(videoId: "a", viewCount: nil, publishedAt: nil, duration: "PT15M33S", channelId: nil, channelTitle: nil).formattedDuration == "15:33")
        #expect(VideoMetadata(videoId: "a", viewCount: nil, publishedAt: nil, duration: "PT1H02M03S", channelId: nil, channelTitle: nil).formattedDuration == "1:02:03")
        #expect(VideoMetadata(videoId: "a", viewCount: nil, publishedAt: nil, duration: "PT45S", channelId: nil, channelTitle: nil).formattedDuration == "0:45")
    }

    @Test("formats relative dates from ISO timestamps")
    func formattedDate() {
        let twoDaysAgo = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-2 * 86_400))
        let oneYearAgo = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-370 * 86_400))

        #expect(VideoMetadata(videoId: "a", viewCount: nil, publishedAt: nil, duration: nil, channelId: nil, channelTitle: nil).formattedDate == nil)
        #expect(VideoMetadata(videoId: "a", viewCount: nil, publishedAt: "not-a-date", duration: nil, channelId: nil, channelTitle: nil).formattedDate == nil)
        #expect(VideoMetadata(videoId: "a", viewCount: nil, publishedAt: twoDaysAgo, duration: nil, channelId: nil, channelTitle: nil).formattedDate == "2 days ago")
        #expect(VideoMetadata(videoId: "a", viewCount: nil, publishedAt: oneYearAgo, duration: nil, channelId: nil, channelTitle: nil).formattedDate == "1 year ago")
    }

    @Test("youtube error descriptions are user facing")
    func errorDescriptions() {
        #expect(YouTubeError.noApiKey.errorDescription == "No YouTube API key found. Set YOUTUBE_API_KEY or GOOGLE_API_KEY env var, or write key to ~/.config/youtube/api-key")
        #expect(YouTubeError.invalidResponse.errorDescription == "Invalid response from YouTube API")
        #expect(YouTubeError.apiError(statusCode: 403, message: "quota").errorDescription == "YouTube API error (403): quota")
    }
}
