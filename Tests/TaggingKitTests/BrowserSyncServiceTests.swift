import Foundation
import Testing
@testable import TaggingKit

@Suite("BrowserSyncService")
struct BrowserSyncServiceTests {

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

    @Test("BrowserSyncError provides user-facing description")
    func errorDescription() {
        let error = BrowserSyncError.executionFailed("Timeout waiting for element")
        #expect(error.localizedDescription == "Timeout waiting for element")
    }

    @Test("execute returns empty result for empty actions")
    func executeEmptyActions() async throws {
        let service = BrowserSyncService(repoRoot: FileManager.default.temporaryDirectory)
        let result = try await service.execute(actions: [])
        #expect(result.syncedActionIDs.isEmpty)
        #expect(result.failures.isEmpty)
    }
}
