import Foundation
import Testing
@testable import TaggingKit

@Suite("DiscoveryFallbackService")
struct DiscoveryFallbackServiceTests {

    @Test("DiscoveryFallbackVideo stores all expected fields")
    func videoModel() {
        let video = DiscoveryFallbackVideo(
            videoId: "abc123",
            title: "Test Video",
            channelTitle: "Test Channel",
            publishedAt: "2026-04-01T00:00:00Z",
            duration: "PT10M",
            viewCount: "1234",
            source: "yt-dlp"
        )
        #expect(video.videoId == "abc123")
        #expect(video.title == "Test Video")
        #expect(video.channelTitle == "Test Channel")
        #expect(video.source == "yt-dlp")
    }

    @Test("DiscoveryFallbackError provides user-facing description")
    func errorDescription() {
        let error = DiscoveryFallbackError.executionFailed("Python not found")
        #expect(error.localizedDescription == "Python not found")
    }

    @Test("DiscoveryFallbackVideo handles nil optional fields")
    func videoModelWithNils() {
        let video = DiscoveryFallbackVideo(
            videoId: "xyz",
            title: "Minimal",
            channelTitle: nil,
            publishedAt: nil,
            duration: nil,
            viewCount: nil,
            source: "rss"
        )
        #expect(video.channelTitle == nil)
        #expect(video.publishedAt == nil)
        #expect(video.duration == nil)
        #expect(video.viewCount == nil)
    }
}
