import Foundation
import TaggingKit

extension OrganizerStore {
    /// Phase 3: on-demand "Load full upload history" entry point for the creator
    /// detail page. Triggers a single deeper scrape of the channel via the existing
    /// `DiscoveryFallbackService` (max 200 results, the cap raised in Phase 3),
    /// merges new rows into `channel_discovery_archive`, and stamps the result
    /// count into `lastFullHistoryLoadCount` so the view can surface feedback.
    ///
    /// ## Cache invalidation policy (Phase 3 #19)
    ///
    /// The channel discovery archive has three refresh paths, each with a
    /// different policy chosen for its access pattern:
    ///
    /// 1. **Background auto-refresh (Watch discovery)** — fires from
    ///    `refreshChannelArchiveIfNeeded` during Watch sync. Stale threshold is
    ///    **12 hours** (`shouldRefreshArchive` in `OrganizerStore+CandidateDiscovery`).
    ///    Fetches 16 newest videos. Per-channel, scraper-first, free.
    ///
    /// 2. **Manual deep load (this method)** — user clicks "Load full history"
    ///    on the creator page. **No staleness gate** — runs whenever the user
    ///    asks. Fetches up to 200 videos. Self-throttles to one concurrent run
    ///    per channel via `loadingFullHistoryChannels`.
    ///
    /// 3. **Visual stale flag** — the creator page "Last refreshed" row shows
    ///    "X days old" suffix when the archive's `fetchedAt` is **more than 7
    ///    days** old, prompting the user to consider clicking the manual load
    ///    button. Implemented in `CreatorDetailView.refreshedRowValue`.
    ///
    /// Self-throttling: refuses to start a second concurrent run for the same
    /// channel. Once per page open per channel is the intended cadence; the view
    /// gates the button on `loadingFullHistoryChannels` membership.
    func loadFullChannelHistory(channelId: String, channelName: String) {
        guard !loadingFullHistoryChannels.contains(channelId) else { return }
        loadingFullHistoryChannels.insert(channelId)
        // Clear any prior count so the view can distinguish "in progress" from
        // "previously completed" by checking the set vs the map.
        lastFullHistoryLoadCount.removeValue(forKey: channelId)
        AppLogger.app.info("Loading full upload history for \(channelName, privacy: .public) (\(channelId, privacy: .public))")

        Task { @MainActor in
            defer { loadingFullHistoryChannels.remove(channelId) }
            do {
                let knownIds = try store.archivedVideoIDsForChannel(channelId)
                let scraped = try await DiscoveryFallbackService(environment: runtimeEnvironment)
                    .fetchRecentChannelUploads(channelId: channelId, maxResults: 200)
                let newOnly = scraped.filter { !knownIds.contains($0.videoId) }
                guard !newOnly.isEmpty else {
                    lastFullHistoryLoadCount[channelId] = 0
                    AppLogger.app.info("Full history load found 0 new videos for \(channelId, privacy: .public)")
                    return
                }

                let scannedAt = ISO8601DateFormatter().string(from: Date())
                // Resolve the channel record so we can carry the existing icon URL
                // through to new rows. The archive table requires non-nil channel
                // metadata for downstream consumers (creator page builder, etc.).
                let channelRecord = (try? store.channelById(channelId)) ?? nil
                let archived = newOnly.map { video in
                    ArchivedChannelVideo(
                        channelId: channelId,
                        videoId: video.videoId,
                        title: video.title,
                        channelName: video.channelTitle ?? channelRecord?.name ?? channelName,
                        publishedAt: video.publishedAt,
                        duration: video.duration,
                        viewCount: video.viewCount,
                        channelIconUrl: channelRecord?.iconUrl,
                        fetchedAt: scannedAt
                    )
                }
                try store.upsertChannelDiscoveryArchive(
                    channelId: channelId,
                    videos: archived,
                    scannedAt: scannedAt
                )
                lastFullHistoryLoadCount[channelId] = newOnly.count
                AppLogger.app.info("Full history load added \(newOnly.count) new videos for \(channelId, privacy: .public)")
            } catch {
                AppLogger.app.error("Full history load failed for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastFullHistoryLoadCount[channelId] = 0
            }
        }
    }
}
