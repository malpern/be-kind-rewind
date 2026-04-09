import Foundation
import Testing
@testable import TaggingKit

@Suite("YouTubeSyncService")
struct YouTubeSyncServiceTests {

    @Test("Watch Later actions are deferred to browser executor")
    func watchLaterDeferred() async {
        let action = SyncAction(
            id: 1, videoId: "vid-1", action: "add_to_playlist",
            playlist: "WL", playlistTitle: "Watch Later",
            executor: .browser, attempts: 0, lastError: nil
        )

        // Use a real client that will defer WL before hitting the network
        let client = try! YouTubeClient(apiKey: "test-key-not-used")
        let service = YouTubeSyncService(client: client)
        let result = await service.sync(actions: [action])

        #expect(result.syncedActionIDs.isEmpty)
        #expect(result.deferredActions.count == 1)
        #expect(result.deferredActions.first?.id == 1)
        #expect(result.failures.isEmpty)
    }

    @Test("not_interested actions are deferred to browser executor")
    func notInterestedDeferred() async {
        let action = SyncAction(
            id: 2, videoId: "vid-2", action: "not_interested",
            playlist: "__youtube__", playlistTitle: nil,
            executor: .browser, attempts: 0, lastError: nil
        )

        let client = try! YouTubeClient(apiKey: "test-key-not-used")
        let service = YouTubeSyncService(client: client)
        let result = await service.sync(actions: [action])

        #expect(result.syncedActionIDs.isEmpty)
        #expect(result.deferredActions.count == 1)
        #expect(result.deferredActions.first?.id == 2)
    }

    @Test("unsupported action type produces a failure")
    func unsupportedAction() async {
        let action = SyncAction(
            id: 3, videoId: "vid-3", action: "unknown_action",
            playlist: "PL-1", playlistTitle: "My Playlist",
            executor: .api, attempts: 0, lastError: nil
        )

        let client = try! YouTubeClient(apiKey: "test-key-not-used")
        let service = YouTubeSyncService(client: client)
        let result = await service.sync(actions: [action])

        #expect(result.syncedActionIDs.isEmpty)
        #expect(result.deferredActions.isEmpty)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.message.contains("Unsupported") == true)
    }

    @Test("YouTubeSyncResult stores all fields")
    func resultModel() {
        let result = YouTubeSyncResult(
            syncedActionIDs: [1, 2],
            deferredActions: [],
            failures: []
        )
        #expect(result.syncedActionIDs == [1, 2])
        #expect(result.deferredActions.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test("SyncExecutionOutcome stores all fields")
    func outcomeModel() {
        let outcome = SyncExecutionOutcome(
            syncedActionIDs: [1],
            deferredActionIDs: [2],
            browserFallbackActionIDs: [3],
            failures: [SyncFailureRecord(id: 4, message: "error")]
        )
        #expect(outcome.syncedActionIDs == [1])
        #expect(outcome.deferredActionIDs == [2])
        #expect(outcome.browserFallbackActionIDs == [3])
        #expect(outcome.failures.count == 1)
    }

    @Test("execute wraps sync and separates deferred from browser fallback")
    func executeDeferral() async {
        let actions = [
            SyncAction(
                id: 10, videoId: "vid-wl", action: "add_to_playlist",
                playlist: "WL", playlistTitle: "Watch Later",
                executor: .browser, attempts: 0, lastError: nil
            ),
            SyncAction(
                id: 11, videoId: "vid-ni", action: "not_interested",
                playlist: "__youtube__", playlistTitle: nil,
                executor: .browser, attempts: 0, lastError: nil
            )
        ]

        let client = try! YouTubeClient(apiKey: "test-key-not-used")
        let service = YouTubeSyncService(client: client)
        let outcome = await service.execute(actions: actions)

        #expect(outcome.syncedActionIDs.isEmpty)
        #expect(outcome.deferredActionIDs.count == 2)
        #expect(outcome.browserFallbackActionIDs.isEmpty)
        #expect(outcome.failures.isEmpty)
    }
}
