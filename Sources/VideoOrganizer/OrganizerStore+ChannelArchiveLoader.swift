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
        // Clear any prior count + error so the view can distinguish "in
        // progress" from "previously completed" by checking the set vs the map.
        lastFullHistoryLoadCount.removeValue(forKey: channelId)
        lastFullHistoryLoadError.removeValue(forKey: channelId)
        AppLogger.app.info("Loading full upload history for \(channelName, privacy: .public) (\(channelId, privacy: .public))")
        AppLogger.file.log("loadFullChannelHistory(\(channelName) / \(channelId)) start", category: "discovery")

        Task { @MainActor in
            defer {
                loadingFullHistoryChannels.remove(channelId)
                refreshScrapeHealth()
            }
            do {
                let knownIds = try store.archivedVideoIDsForChannel(channelId)
                let scraped = try await DiscoveryFallbackService(environment: runtimeEnvironment)
                    .fetchRecentChannelUploads(channelId: channelId, maxResults: 400)
                let newOnly = scraped.filter { !knownIds.contains($0.videoId) }
                guard !newOnly.isEmpty else {
                    lastFullHistoryLoadCount[channelId] = 0
                    AppLogger.app.info("Full history load found 0 new videos for \(channelId, privacy: .public)")
                    AppLogger.file.log("loadFullChannelHistory(\(channelId)) returned 0 new (scraper saw \(scraped.count) total)", category: "discovery")
                    return
                }

                let scannedAt = ISO8601DateFormatter().string(from: Date())
                // Resolve the channel record so we can carry the existing icon URL
                // through to new rows. The archive table requires non-nil channel
                // metadata for downstream consumers (creator page builder, etc.).
                let channelRecord = (try? store.channelById(channelId)) ?? nil
                let now = Date()
                let archived = newOnly.map { video in
                    ArchivedChannelVideo(
                        channelId: channelId,
                        videoId: video.videoId,
                        title: video.title,
                        channelName: video.channelTitle ?? channelRecord?.name ?? channelName,
                        // Phase 3 fix: scrapetube returns relative date strings
                        // ("5 years ago", "2 months ago") which can't be parsed by
                        // parseISO8601Date. Normalize to a real ISO 8601 timestamp
                        // here so cadence/sort/recency-weighted topic mix work
                        // for archived videos. The conversion is approximate
                        // (relative dates have low precision) but close enough.
                        publishedAt: Self.normalizePublishedAt(video.publishedAt, now: now),
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
                AppLogger.file.log("loadFullChannelHistory(\(channelId)) added \(newOnly.count) new videos", category: "discovery")

                // Trigger theme classification now that the archive is populated.
                // Previously handled by a view-layer .onChange that could miss
                // the fire when its host view (emptyArchiveBanner) unmounted on
                // archive completion.
                classifyCreatorThemesIfNeeded(channelId: channelId, channelName: channelName)
            } catch {
                let reason = error.localizedDescription
                AppLogger.app.error("Full history load failed for \(channelId, privacy: .public): \(reason, privacy: .public)")
                AppLogger.file.log("loadFullChannelHistory(\(channelId)) FAILED: \(reason)", category: "discovery")
                lastFullHistoryLoadCount[channelId] = 0
                lastFullHistoryLoadError[channelId] = reason
            }
        }
    }

    /// Phase 3 migration: walks the archive once on app launch to rewrite
    /// historical rows where `published_at` is a relative-date string ("5 years
    /// ago" etc.) into proper ISO 8601 timestamps. Gated by a UserDefaults
    /// flag so it only runs once per install. Safe to call multiple times.
    func backfillArchivePublishedAtIfNeeded() {
        // V2 of the migration adds support for abbreviated relative-date units
        // ("5y ago", "2mo ago", "3w", etc.) that V1 missed. Bump the key so
        // installs that already ran V1 re-run with the improved parser.
        let migrationKey = "archivePublishedAtNormalizedV2"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        do {
            let rows = try store.archiveRowsWithRelativePublishedAt()
            guard !rows.isEmpty else {
                UserDefaults.standard.set(true, forKey: migrationKey)
                return
            }
            AppLogger.app.info("Backfilling normalized published_at for \(rows.count, privacy: .public) archive rows")
            AppLogger.file.log("backfillArchivePublishedAt: \(rows.count) rows to migrate", category: "discovery")
            let now = Date()
            var fixed = 0
            var skipped = 0
            for (channelId, videoId, raw) in rows {
                guard let normalized = Self.normalizePublishedAt(raw, now: now) else {
                    skipped += 1
                    continue
                }
                try store.updateArchivePublishedAt(
                    channelId: channelId,
                    videoId: videoId,
                    publishedAt: normalized
                )
                fixed += 1
            }
            AppLogger.app.info("Archive published_at backfill: fixed=\(fixed, privacy: .public) skipped=\(skipped, privacy: .public)")
            AppLogger.file.log("backfillArchivePublishedAt: fixed=\(fixed) skipped=\(skipped)", category: "discovery")
            UserDefaults.standard.set(true, forKey: migrationKey)
        } catch {
            AppLogger.app.error("Archive published_at backfill failed: \(error.localizedDescription, privacy: .public)")
            AppLogger.file.log("backfillArchivePublishedAt FAILED: \(error.localizedDescription)", category: "discovery")
            // Don't set the migration flag — try again on next launch.
        }
    }

    /// Phase 3: convert a publishedAt string to a normalized ISO 8601 timestamp.
    /// scrapetube returns relative-date strings like "5 years ago" / "2 months ago"
    /// which can't be parsed by `CreatorAnalytics.parseISO8601Date`, breaking the
    /// monthly cadence chart, recency-weighted topic mix, and "new since last
    /// visit" computation for archived videos.
    ///
    /// The conversion is intentionally approximate — relative dates have month
    /// granularity at best — but accurate enough for grouping and sorting. If
    /// the input already looks like an ISO 8601 timestamp it's returned as-is.
    /// nil for unparseable inputs (e.g. localized strings we don't handle yet).
    static func normalizePublishedAt(_ raw: String?, now: Date = Date()) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        // Already ISO 8601? Pass through unchanged.
        if CreatorAnalytics.parseISO8601Date(raw) != nil {
            return raw
        }
        // Parse "5 years ago", "2 months ago", "1 week ago", "3 days ago",
        // "5 hours ago", "30 minutes ago", "Just now", etc.
        let lower = raw.lowercased()
        let calendar = Calendar(identifier: .gregorian)
        if lower.contains("just now") || lower == "now" {
            return ISO8601DateFormatter().string(from: now)
        }
        // Pull out the leading integer.
        let scanner = Scanner(string: lower)
        var amount: Int = 0
        guard scanner.scanInt(&amount) else {
            // Unparseable — return nil so the field is treated as "unknown"
            // rather than persisting a string that breaks downstream parsers.
            return nil
        }
        // Pull out the unit token immediately after the integer (e.g. "5y ago",
        // "5 years ago", "2mo ago", "3w", "30m"). We strip the leading digits
        // to get the unit substring, then match by both full and abbreviated
        // forms. Order matters: check "month"/"mo" before "minute"/"m" so we
        // don't misclassify "2mo" as 2 minutes.
        let unitSubstring = lower
            .drop { $0.isNumber || $0.isWhitespace }
        let component: Calendar.Component?
        if unitSubstring.hasPrefix("year") || unitSubstring.hasPrefix("y") {
            component = .year
        } else if unitSubstring.hasPrefix("month") || unitSubstring.hasPrefix("mo") {
            component = .month
        } else if unitSubstring.hasPrefix("week") || unitSubstring.hasPrefix("w") {
            component = .weekOfYear
        } else if unitSubstring.hasPrefix("day") || unitSubstring.hasPrefix("d") {
            component = .day
        } else if unitSubstring.hasPrefix("hour") || unitSubstring.hasPrefix("h") {
            component = .hour
        } else if unitSubstring.hasPrefix("minute") || unitSubstring.hasPrefix("min") || unitSubstring.hasPrefix("m") {
            component = .minute
        } else if unitSubstring.hasPrefix("second") || unitSubstring.hasPrefix("sec") || unitSubstring.hasPrefix("s") {
            component = .second
        } else {
            component = nil
        }
        guard let component,
              let date = calendar.date(byAdding: component, value: -amount, to: now) else {
            return nil
        }
        return ISO8601DateFormatter().string(from: date)
    }
}
