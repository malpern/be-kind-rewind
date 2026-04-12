import Foundation
@preconcurrency import SQLite

extension TopicStore {
    public func addPlaylistMembership(_ membership: PlaylistMembershipRecord) throws {
        try db.run(playlistMemberships.insert(or: .replace,
            membershipPlaylistId <- membership.playlistId,
            membershipVideoId <- membership.videoId,
            membershipPosition <- membership.position,
            membershipVerifiedAt <- membership.verifiedAt
        ))
    }

    public func removePlaylistMembership(playlistId pid: String, videoId vid: String) throws {
        try db.run(playlistMemberships.filter(membershipPlaylistId == pid && membershipVideoId == vid).delete())
    }

    public func queueCommit(action: String, videoId vid: String, playlist: String) throws {
        let executor: SyncExecutorKind
        if action == "not_interested" || (action == "add_to_playlist" && playlist == "WL") {
            executor = .browser
        } else {
            executor = .api
        }
        let now = ISO8601DateFormatter().string(from: Date())
        try db.run(commitLog.insert(
            commitAction <- action,
            commitVideoId <- vid,
            commitPlaylist <- playlist,
            commitCreatedAt <- now,
            commitSynced <- false,
            commitState <- SyncQueueState.queued.rawValue,
            commitAttempts <- 0,
            commitLastError <- nil,
            commitNextAttemptAt <- nil,
            commitExecutor <- executor.rawValue,
            commitStateUpdatedAt <- now
        ))
    }

    public func pendingSyncPlan(
        executor: SyncExecutorKind? = nil,
        now: Date = Date()
    ) throws -> [SyncAction] {
        let nowString = ISO8601DateFormatter().string(from: now)
        var pending = commitLog
            .filter(commitSynced == false)
            .filter(commitState == SyncQueueState.queued.rawValue
                || commitState == SyncQueueState.retrying.rawValue
                || commitState == SyncQueueState.deferred.rawValue)
            .filter(commitNextAttemptAt == nil || commitNextAttemptAt <= nowString)
            .order(commitCreatedAt)
        if let executor {
            pending = pending.filter(commitExecutor == executor.rawValue)
        }
        var latestAction: [String: SyncAction] = [:]

        for row in try db.prepare(pending) {
            let action = row[commitAction]
            let videoId = row[commitVideoId]
            let playlist = row[commitPlaylist]
            let playlistTitle = try? playlistTitle(for: playlist)
            let key: String
            switch action {
            case "add_to_playlist", "remove_from_playlist":
                key = "\(action):\(playlist):\(videoId)"
            case "not_interested":
                key = "\(action):\(videoId)"
            default:
                key = "\(action):\(playlist):\(videoId)"
            }

            latestAction[key] = SyncAction(
                id: row[commitId],
                videoId: videoId,
                action: action,
                playlist: playlist,
                playlistTitle: playlistTitle,
                executor: SyncExecutorKind(rawValue: row[commitExecutor]) ?? .api,
                attempts: row[commitAttempts],
                lastError: row[commitLastError]
            )
        }

        return latestAction.values.sorted { lhs, rhs in
            if lhs.videoId == rhs.videoId {
                return lhs.id < rhs.id
            }
            return lhs.videoId < rhs.videoId
        }
    }

    public func markSynced(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try db.run(commitLog.filter(ids.contains(commitId)).update(
            commitSynced <- true,
            commitState <- SyncQueueState.synced.rawValue,
            commitLastError <- nil,
            commitNextAttemptAt <- nil,
            commitStateUpdatedAt <- now
        ))
    }

    public func markSynced() throws {
        let ids = try db.prepare(commitLog.filter(commitSynced == false).select(commitId)).map { $0[commitId] }
        try markSynced(ids: ids)
    }

    public func markInProgress(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try db.run(commitLog.filter(ids.contains(commitId)).update(
            commitState <- SyncQueueState.inProgress.rawValue,
            commitAttempts <- commitAttempts + 1,
            commitLastError <- nil,
            commitStateUpdatedAt <- now
        ))
    }

    public func markDeferred(ids: [Int64], error: String? = nil) throws {
        guard !ids.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try db.run(commitLog.filter(ids.contains(commitId)).update(
            commitState <- SyncQueueState.deferred.rawValue,
            commitLastError <- error,
            commitStateUpdatedAt <- now
        ))
    }

    public func moveToExecutor(ids: [Int64], executor: SyncExecutorKind, state: SyncQueueState, error: String? = nil) throws {
        guard !ids.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try db.run(commitLog.filter(ids.contains(commitId)).update(
            commitExecutor <- executor.rawValue,
            commitState <- state.rawValue,
            commitLastError <- error,
            commitNextAttemptAt <- nil,
            commitStateUpdatedAt <- now
        ))
    }

    public func markFailed(_ failures: [SyncFailureRecord], retryAfter: TimeInterval?) throws {
        guard !failures.isEmpty else { return }
        try db.transaction {
            let retryDate = retryAfter.map { ISO8601DateFormatter().string(from: Date().addingTimeInterval($0)) }
            let now = ISO8601DateFormatter().string(from: Date())
            for failure in failures {
                try db.run(commitLog.filter(commitId == failure.id).update(
                    commitState <- SyncQueueState.retrying.rawValue,
                    commitLastError <- failure.message,
                    commitNextAttemptAt <- retryDate,
                    commitStateUpdatedAt <- now
                ))
            }
        }
    }

    public func recoverStaleInProgressCommits(olderThan age: TimeInterval = 5 * 60, now: Date = Date()) throws -> Int {
        let formatter = ISO8601DateFormatter()
        let cutoff = formatter.string(from: now.addingTimeInterval(-age))
        let query = commitLog
            .filter(commitSynced == false)
            .filter(commitState == SyncQueueState.inProgress.rawValue)
            .filter(commitStateUpdatedAt <= cutoff)

        let staleIds = try db.prepare(query.select(commitId)).map { $0[commitId] }
        guard !staleIds.isEmpty else { return 0 }

        let nowString = formatter.string(from: now)
        try db.run(commitLog.filter(staleIds.contains(commitId)).update(
            commitState <- SyncQueueState.retrying.rawValue,
            commitLastError <- "Recovered after interrupted sync.",
            commitNextAttemptAt <- nil,
            commitStateUpdatedAt <- nowString
        ))

        return staleIds.count
    }

    public func syncQueueSummary() throws -> SyncQueueSummary {
        func count(_ state: SyncQueueState? = nil, executor: SyncExecutorKind? = nil) throws -> Int {
            var query = commitLog.filter(commitSynced == false)
            if let state {
                query = query.filter(commitState == state.rawValue)
            }
            if let executor {
                query = query.filter(commitExecutor == executor.rawValue)
            }
            return try db.scalar(query.count)
        }

        return SyncQueueSummary(
            queued: try count(.queued),
            retrying: try count(.retrying),
            deferred: try count(.deferred),
            inProgress: try count(.inProgress),
            browserDeferred: try count(.deferred, executor: .browser)
        )
    }

    public func playlistTitle(for playlistId: String) throws -> String? {
        try db.pluck(playlists.filter(self.playlistId == playlistId).select(playlistTitle))?[playlistTitle]
    }
}
