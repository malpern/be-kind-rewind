import Foundation
import TaggingKit

extension OrganizerStore {
    /// Phase 3: fetch a creator's external links from their YouTube channel
    /// home page if we don't already have them cached. Auto-triggered from
    /// the creator detail page's `.task` for any channel that has no row in
    /// `channel_links` yet. Cached forever once successful — re-scrapes only
    /// happen via a future manual refresh affordance (not implemented yet).
    ///
    /// The scrape itself is bounded by the existing ScrapeRateLimiter so it
    /// shares the global politeness layer with archive and search scrapes.
    /// Empty links is a valid result (the creator may not publish any URLs)
    /// and gets stored as an empty array so we don't keep retrying.
    func loadChannelLinksIfNeeded(channelId: String) {
        guard !loadingChannelLinks.contains(channelId) else { return }

        // If we already have a cached row (even an empty one), skip the scrape.
        // The user can force a refresh later if needed.
        if let cached = try? store.channelLinksForChannel(channelId), cached != nil {
            return
        }

        loadingChannelLinks.insert(channelId)
        AppLogger.file.log("loadChannelLinksIfNeeded(\(channelId)) start", category: "discovery")

        Task { @MainActor in
            defer {
                loadingChannelLinks.remove(channelId)
                refreshScrapeHealth()
            }
            do {
                let links = try await DiscoveryFallbackService(environment: runtimeEnvironment)
                    .fetchChannelLinks(channelId: channelId)
                try store.setChannelLinks(channelId: channelId, links: links)
                AppLogger.file.log("loadChannelLinksIfNeeded(\(channelId)) cached \(links.count) link(s)", category: "discovery")
                // Trigger a page rebuild so any open creator page picks up the
                // new links. Cheap because the builder is fast (~80ms post-fix).
                channelLinksVersion &+= 1
            } catch {
                AppLogger.file.log("loadChannelLinksIfNeeded(\(channelId)) FAILED: \(error.localizedDescription)", category: "discovery")
                // Don't store anything on failure — leave the cache empty so
                // the next page open retries (subject to the rate limiter's
                // per-channel cooldown which already gates this for 10 minutes
                // after a failure).
            }
        }
    }
}
