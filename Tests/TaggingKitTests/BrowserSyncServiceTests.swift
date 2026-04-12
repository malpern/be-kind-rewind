import Foundation
import Testing
@testable import TaggingKit

@Suite("BrowserSyncService")
struct BrowserSyncServiceTests {
    private let sampleAction = SyncAction(
        id: 1,
        videoId: "vid-123",
        action: "not_interested",
        playlist: "WL",
        playlistTitle: nil,
        executor: .browser,
        attempts: 0,
        lastError: nil
    )

    @Test("BrowserSyncResult captures synced IDs and failures")
    func resultModel() {
        let result = BrowserSyncResult(
            syncedActionIDs: [1, 2, 3],
            failures: [SyncFailureRecord(id: 4, message: "video not found")]
        )
        #expect(result.syncedActionIDs == [1, 2, 3])
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.message == "video not found")
    }

    @Test("BrowserExecutorStatus reports readiness and message")
    func statusModel() {
        let ready = BrowserExecutorStatus(ready: true, message: "Signed in to YouTube")
        let notReady = BrowserExecutorStatus(ready: false, message: "Not signed in")
        #expect(ready.ready)
        #expect(!notReady.ready)
        #expect(notReady.message == "Not signed in")
    }

    @Test("BrowserRelatedVideo stores signed-in related recommendation fields")
    func relatedVideoModel() {
        let related = BrowserRelatedVideo(
            seedVideoId: "seed-1",
            videoId: "vid-123",
            title: "Recommended SwiftUI Video",
            channelId: "chan-1",
            channelTitle: "Alpha Channel",
            publishedAt: "2 days ago",
            duration: "12:34",
            viewCount: "12K views"
        )

        #expect(related.seedVideoId == "seed-1")
        #expect(related.videoId == "vid-123")
        #expect(related.channelId == "chan-1")
        #expect(related.channelTitle == "Alpha Channel")
    }

    @Test("BrowserSyncError provides user-facing description")
    func errorDescription() {
        let error = BrowserSyncError.executionFailed("Timeout waiting for element")
        #expect(error.localizedDescription == "Timeout waiting for element")
    }

    @Test("BrowserSyncError missingDependency provides user-facing description")
    func missingDependencyErrorDescription() {
        let error = BrowserSyncError.missingDependency("Required command 'npx' is not installed or not on PATH.")
        #expect(error.localizedDescription == "Required command 'npx' is not installed or not on PATH.")
    }

    @Test("execute returns empty result for empty actions")
    func executeEmptyActions() async throws {
        let service = BrowserSyncService(repoRoot: FileManager.default.temporaryDirectory)
        let result = try await service.execute(actions: [])
        #expect(result.syncedActionIDs.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test("execute surfaces a missing browser sync script before launching subprocesses")
    func executeMissingScript() async {
        let repoRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let service = BrowserSyncService(repoRoot: repoRoot)

        await #expect(throws: BrowserSyncError.self) {
            _ = try await service.execute(actions: [sampleAction])
        }
    }

    @Test("openLoginSetup surfaces a missing browser sync script before launching subprocesses")
    func openLoginSetupMissingScript() async {
        let repoRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let service = BrowserSyncService(repoRoot: repoRoot)

        await #expect(throws: BrowserSyncError.self) {
            try await service.openLoginSetup()
        }
    }

    @Test("fetchRelatedVideos returns empty result for empty seeds")
    func fetchRelatedVideosEmptySeeds() async throws {
        let service = BrowserSyncService(repoRoot: FileManager.default.temporaryDirectory)
        let result = try await service.fetchRelatedVideos(seedVideoIds: [])
        #expect(result.isEmpty)
    }
}
