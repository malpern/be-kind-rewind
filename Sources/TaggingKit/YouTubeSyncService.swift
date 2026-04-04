import Foundation

public struct YouTubeSyncFailure: Sendable {
    public let action: SyncAction
    public let message: String
    public let underlyingError: Error?

    public init(action: SyncAction, message: String, underlyingError: Error? = nil) {
        self.action = action
        self.message = message
        self.underlyingError = underlyingError
    }
}

public struct YouTubeSyncResult: Sendable {
    public let syncedActionIDs: [Int64]
    public let deferredActions: [SyncAction]
    public let failures: [YouTubeSyncFailure]

    public init(syncedActionIDs: [Int64], deferredActions: [SyncAction], failures: [YouTubeSyncFailure]) {
        self.syncedActionIDs = syncedActionIDs
        self.deferredActions = deferredActions
        self.failures = failures
    }
}

public struct SyncExecutionOutcome: Sendable {
    public let syncedActionIDs: [Int64]
    public let deferredActionIDs: [Int64]
    public let browserFallbackActionIDs: [Int64]
    public let failures: [SyncFailureRecord]

    public init(syncedActionIDs: [Int64], deferredActionIDs: [Int64], browserFallbackActionIDs: [Int64], failures: [SyncFailureRecord]) {
        self.syncedActionIDs = syncedActionIDs
        self.deferredActionIDs = deferredActionIDs
        self.browserFallbackActionIDs = browserFallbackActionIDs
        self.failures = failures
    }
}

public struct YouTubeSyncService: Sendable {
    private let client: YouTubeClient

    public init(client: YouTubeClient) {
        self.client = client
    }

    public func sync(actions: [SyncAction]) async -> YouTubeSyncResult {
        var syncedActionIDs: [Int64] = []
        var deferredActions: [SyncAction] = []
        var failures: [YouTubeSyncFailure] = []

        for action in actions {
            do {
                switch action.action {
                case "add_to_playlist":
                    try await client.addVideoToPlaylist(videoId: action.videoId, playlistId: action.playlist)
                    syncedActionIDs.append(action.id)
                case "not_interested":
                    deferredActions.append(action)
                default:
                    failures.append(YouTubeSyncFailure(action: action, message: "Unsupported sync action: \(action.action)"))
                }
            } catch {
                failures.append(YouTubeSyncFailure(action: action, message: error.localizedDescription, underlyingError: error))
            }
        }

        return YouTubeSyncResult(
            syncedActionIDs: syncedActionIDs,
            deferredActions: deferredActions,
            failures: failures
        )
    }

    public func execute(actions: [SyncAction]) async -> SyncExecutionOutcome {
        let result = await sync(actions: actions)
        let browserFallbackActionIDs: [Int64] = result.failures.compactMap { failure in
            guard let youtubeError = failure.underlyingError as? YouTubeError,
                  youtubeError.isQuotaExceeded,
                  failure.action.action == "add_to_playlist"
            else {
                return nil
            }
            return failure.action.id
        }
        let filteredFailures = result.failures
            .filter { failure in
                !browserFallbackActionIDs.contains(failure.action.id)
            }
        return SyncExecutionOutcome(
            syncedActionIDs: result.syncedActionIDs,
            deferredActionIDs: result.deferredActions.map(\.id),
            browserFallbackActionIDs: browserFallbackActionIDs,
            failures: filteredFailures.map { SyncFailureRecord(id: $0.action.id, message: $0.message) }
        )
    }
}
