import Foundation
import Testing
@testable import VideoOrganizer

@Suite("ThumbnailCache")
struct ThumbnailCacheTests {

    @MainActor
    @Test("localURL returns nil for uncached video")
    func uncachedReturnsNil() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = ThumbnailCache(cacheDir: tempDir)
        #expect(cache.localURL(for: "nonexistent-video") == nil)
    }

    @MainActor
    @Test("localURL returns path for cached thumbnail")
    func cachedReturnPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a fake thumbnail
        let videoId = "test-vid-123"
        let thumbPath = tempDir.appendingPathComponent("\(videoId).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: thumbPath)

        let cache = ThumbnailCache(cacheDir: tempDir)
        let url = cache.localURL(for: videoId)
        #expect(url != nil)
        #expect(url?.lastPathComponent == "\(videoId).jpg")
    }

    @MainActor
    @Test("cacheDirURL returns the configured directory")
    func cacheDirURL() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = ThumbnailCache(cacheDir: tempDir)
        #expect(cache.cacheDirURL == tempDir)
    }

    @MainActor
    @Test("prefetch skips already-cached videos")
    func prefetchSkipsCached() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Pre-cache a thumbnail
        let videoId = "already-cached"
        let thumbPath = tempDir.appendingPathComponent("\(videoId).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: thumbPath)

        // Use a session that would fail if actually used (no network needed)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        let session = URLSession(configuration: config)

        let cache = ThumbnailCache(cacheDir: tempDir, session: session)
        await cache.prefetch(videoIds: [videoId])

        // Should complete without error since it was already cached
        #expect(cache.downloadedCount == 0)
    }
}
