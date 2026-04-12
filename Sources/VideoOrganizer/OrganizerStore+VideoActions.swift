import Foundation
import TaggingKit

/// Candidate dismiss/save/exclude operations and playlist management.
extension OrganizerStore {

    // MARK: - Watch Feedback

    /// "Not for me" — dismiss the video AND record a dislike signal.
    /// The video disappears immediately; the dislike feeds back into
    /// per-creator ranking penalties over time.
    func notForMe(topicId: Int64, videoId: String, channelId: String?, duration: String?) {
        recordFeedback(videoId: videoId, signal: "dislike", channelId: channelId, duration: duration, topicId: topicId)
        setCandidateState(topicId: topicId, videoId: videoId, state: .dismissed)
    }

    /// Record implicit like when user opens a video on YouTube.
    func recordLike(videoId: String, channelId: String?, duration: String?, topicId: Int64?) {
        recordFeedback(videoId: videoId, signal: "like", channelId: channelId, duration: duration, topicId: topicId)
    }

    private func recordFeedback(videoId: String, signal: String, channelId: String?, duration: String?, topicId: Int64?) {
        do {
            try store.recordWatchFeedback(
                videoId: videoId, signal: signal, channelId: channelId,
                duration: duration, topicId: topicId
            )
            refreshCreatorFeedbackCache()
        } catch {
            AppLogger.discovery.error("Failed to record watch feedback for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reload the in-memory per-creator feedback cache from SQLite.
    func refreshCreatorFeedbackCache() {
        do {
            creatorFeedbackCache = try store.allCreatorFeedbackCounts()
        } catch {
            AppLogger.discovery.error("Failed to load creator feedback cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Candidate Mutations

    func dismissCandidate(topicId: Int64, videoId: String) {
        setCandidateState(topicId: topicId, videoId: videoId, state: .dismissed)
    }

    func dismissCandidates(topicId: Int64, videoIds: [String]) {
        // Batch: write all state rows first, then rebuild once.
        // The previous version called dismissCandidate per-video,
        // triggering N full SQL reloads + N pool rebuilds + N
        // impression counter increments.
        for videoId in videoIds {
            do {
                try store.setCandidateState(topicId: topicId, videoId: videoId, state: .dismissed)
            } catch {
                AppLogger.discovery.error("Failed to dismiss candidate \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        reloadStoredCandidateCache(for: topicId)
        rebuildWatchPools()
        candidateRefreshToken += 1
    }

    func excludeCreatorFromWatch(channelId: String?, channelName: String?, channelIconUrl: String? = nil) {
        guard let channelId, !channelId.isEmpty else {
            errorMessage = "This creator cannot be excluded because its channel ID is missing."
            return
        }

        let resolvedName = channelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedName, !resolvedName.isEmpty else {
            errorMessage = "This creator cannot be excluded because its channel name is missing."
            return
        }

        do {
            try store.excludeChannel(
                channelId: channelId,
                channelName: resolvedName,
                iconUrl: channelIconUrl,
                reason: "watch_feedback"
            )
            refreshExcludedCreators()

            if selectedChannelId == channelId {
                selectedChannelId = nil
                inspectedCreatorName = nil
            }

            selectedVideoId = nil
            hoveredVideoId = nil
            rebuildWatchPools()
            candidateRefreshToken += 1
            AppLogger.discovery.info("Excluded creator from watch: \(channelId, privacy: .public)")
            alert = AppAlertState(
                title: "Excluded Creator",
                message: "\(resolvedName) will no longer appear in Watch until you restore them in Settings."
            )
        } catch {
            AppLogger.discovery.error("Failed to exclude creator \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func restoreExcludedCreator(channelId: String) {
        do {
            try store.restoreExcludedChannel(channelId: channelId)
            refreshExcludedCreators()
            rebuildWatchPools()
            candidateRefreshToken += 1
            AppLogger.discovery.info("Restored excluded creator \(channelId, privacy: .public)")
        } catch {
            AppLogger.discovery.error("Failed to restore excluded creator \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func recordOpenedVideo(_ video: VideoGridItemModel) {
        do {
            let imported = try store.recordSeenVideo(
                videoId: video.id,
                title: video.title,
                channelName: video.channelName,
                rawURL: "https://www.youtube.com/watch?v=\(video.id)",
                source: .app,
                confidence: .probable
            )
            if imported > 0 {
                refreshSeenHistoryCount()
            }
        } catch {
            AppLogger.discovery.error("Failed to record app-seen event for \(video.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func markCandidateNotInterested(topicId: Int64, videoId: String) {
        do {
            try store.queueCommit(action: "not_interested", videoId: videoId, playlist: "__youtube__")
            try store.setCandidateState(topicId: topicId, videoId: videoId, state: .dismissed)
            rebuildWatchPools()
            candidateRefreshToken += 1
            AppLogger.discovery.info("Queued not_interested for candidate \(videoId, privacy: .public)")
            alert = AppAlertState(
                title: "Queued Not Interested",
                message: browserExecutorReady
                    ? "This candidate was hidden locally and queued for browser sync to YouTube."
                    : "This candidate was hidden locally. The direct YouTube action is queued, but the browser executor is not signed into YouTube yet."
            )
            if browserExecutorReady {
                processPendingBrowserSync(reason: "not-interested")
            }
        } catch {
            AppLogger.discovery.error("Failed to queue not_interested for candidate \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func markCandidatesNotInterested(topicId: Int64, videoIds: [String]) {
        // Batch: write all state rows + queue commits first, then rebuild
        // once. Same fix as dismissCandidates — avoids N full rebuilds.
        for videoId in videoIds {
            do {
                try store.queueCommit(action: "not_interested", videoId: videoId, playlist: "__youtube__")
                try store.setCandidateState(topicId: topicId, videoId: videoId, state: .dismissed)
            } catch {
                AppLogger.discovery.error("Failed to queue not_interested for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        reloadStoredCandidateCache(for: topicId)
        rebuildWatchPools()
        candidateRefreshToken += 1
        if browserExecutorReady {
            processPendingBrowserSync(reason: "not-interested-batch")
        }
    }

    // MARK: - Playlist Operations

    func saveCandidateToWatchLater(topicId: Int64, videoId: String) {
        let watchLater = PlaylistRecord(
            playlistId: "WL",
            title: "Watch Later",
            visibility: "Private",
            source: "queued",
            fetchedAt: ISO8601DateFormatter().string(from: Date())
        )
        saveCandidateToPlaylist(topicId: topicId, videoId: videoId, playlist: watchLater)
    }

    func saveCandidatesToWatchLater(topicId: Int64, videoIds: [String]) {
        for videoId in videoIds {
            saveCandidateToWatchLater(topicId: topicId, videoId: videoId)
        }
    }

    func saveCandidateToPlaylist(topicId: Int64, videoId: String, playlist: PlaylistRecord) {
        do {
            if playlistsByVideoId[videoId]?.contains(where: { $0.playlistId == playlist.playlistId }) == true {
                return
            }

            try store.upsertPlaylist(playlist)
            try store.addPlaylistMembership(PlaylistMembershipRecord(
                playlistId: playlist.playlistId,
                videoId: videoId,
                position: nil,
                verifiedAt: ISO8601DateFormatter().string(from: Date())
            ))
            try store.queueCommit(action: "add_to_playlist", videoId: videoId, playlist: playlist.playlistId)
            try store.setCandidateState(topicId: topicId, videoId: videoId, state: .saved)

            rebuildPlaylistMaps()
            rebuildWatchPools()
            candidateRefreshToken += 1
            AppLogger.discovery.info("Queued add_to_playlist for candidate \(videoId, privacy: .public) -> \(playlist.playlistId, privacy: .public)")
            if playlist.playlistId == "WL" {
                processPendingBrowserSync(reason: "save-candidate-watch-later")
            } else {
                processPendingSync(reason: "save-candidate")
            }
        } catch {
            AppLogger.discovery.error("Failed to queue add_to_playlist for candidate \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func saveCandidatesToPlaylist(topicId: Int64, videoIds: [String], playlist: PlaylistRecord) {
        for videoId in videoIds {
            saveCandidateToPlaylist(topicId: topicId, videoId: videoId, playlist: playlist)
        }
    }

    func saveVideosToWatchLater(videoIds: [String]) {
        let watchLater = PlaylistRecord(
            playlistId: "WL",
            title: "Watch Later",
            visibility: "Private",
            source: "queued",
            fetchedAt: ISO8601DateFormatter().string(from: Date())
        )
        saveVideosToPlaylist(videoIds: videoIds, playlist: watchLater)
    }

    func saveVideosToPlaylist(videoIds: [String], playlist: PlaylistRecord) {
        do {
            try store.upsertPlaylist(playlist)
            let now = ISO8601DateFormatter().string(from: Date())
            for videoId in videoIds {
                if playlistsByVideoId[videoId]?.contains(where: { $0.playlistId == playlist.playlistId }) == true {
                    continue
                }
                try store.addPlaylistMembership(PlaylistMembershipRecord(
                    playlistId: playlist.playlistId,
                    videoId: videoId,
                    position: nil,
                    verifiedAt: now
                ))
                try store.queueCommit(action: "add_to_playlist", videoId: videoId, playlist: playlist.playlistId)
            }

            rebuildPlaylistMaps()
            AppLogger.discovery.info("Queued add_to_playlist for \(videoIds.count, privacy: .public) saved videos -> \(playlist.playlistId, privacy: .public)")
            if playlist.playlistId == "WL" {
                processPendingBrowserSync(reason: "save-library-videos-watch-later")
            } else {
                processPendingSync(reason: "save-library-videos")
            }
        } catch {
            AppLogger.discovery.error("Failed to queue add_to_playlist for saved videos: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func removeVideosFromPlaylist(videoIds: [String], playlist: PlaylistRecord) {
        do {
            for videoId in videoIds {
                guard playlistsByVideoId[videoId]?.contains(where: { $0.playlistId == playlist.playlistId }) == true else {
                    continue
                }
                try store.removePlaylistMembership(playlistId: playlist.playlistId, videoId: videoId)
                try store.queueCommit(action: "remove_from_playlist", videoId: videoId, playlist: playlist.playlistId)
            }

            rebuildPlaylistMaps()
            AppLogger.discovery.info("Queued remove_from_playlist for \(videoIds.count, privacy: .public) saved videos <- \(playlist.playlistId, privacy: .public)")
            processPendingSync(reason: "remove-library-videos")
        } catch {
            AppLogger.discovery.error("Failed to queue remove_from_playlist for saved videos: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}
