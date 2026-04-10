# Watch Mode Architecture

How the Watch tab discovers, ranks, and displays video candidates.

## Overview

Watch mode shows videos you haven't seen from channels related to your saved
topics. It uses a **scraper-first** approach: web scraping handles all read
operations (channel uploads, search, channel icons) with the YouTube Data API
as a fallback. The API is reserved for write operations (playlist sync).

## Discovery Pipeline

When you switch to Watch, `ensureCandidatesForWatchPage()` iterates all topics:

```
User clicks Watch
  -> activatePageDisplayMode(.watchCandidates)
  -> ensureCandidatesForWatchPage()
     |
     For each topic (prioritized: selected > visible > remaining):
     |
     1. Check shouldUseCachedCandidates (6-hour window)
     |   -> YES: skip to icon fetch
     |   -> NO: run ensureCandidates(for: topicId)
     |
     2. ensureCandidates(for:) does two things:
     |   a. Channel archive refresh (scraper-first):
     |      - Try DiscoveryFallbackService (scrapetube/RSS)
     |      - Fall back to YouTubeClient.fetchIncrementalChannelUploads
     |      - Store results in channel_discovery_archive table
     |
     |   b. Video search (scraper-first):
     |      - Try DiscoveryFallbackService.searchVideos (scrapetube)
     |      - Fall back to YouTubeClient.searchVideos
     |
     3. Rank candidates by score, store top 36 per topic
     4. Fetch missing channel icons (scraper-first):
     |   - Scrape channel pages for avatar URLs (youtube_channel_icons.py)
     |   - Fall back to YouTubeClient.fetchChannelThumbnails
     |   - Download icon images from CDN (free)
     |   - Cache in channels table as icon_data blob
     |
     5. Rebuild watch pools, increment counter
```

## Caching & Fast Path

- **6-hour candidate cache**: `shouldUseCachedCandidates` checks the latest
  `discovered_at` timestamp. If under 6 hours old, skips re-discovery.
- **All-fresh fast path**: If ALL topics have fresh candidates, the entire
  refresh loop is skipped — just rebuild watch pools from cached data. This
  makes Save -> Watch -> Save -> Watch instant.
- **Icon data cache**: Channel icons are stored as binary blobs in the
  `channels` table. Once fetched, they never need re-downloading.
- **Watch pool materialization**: `watchPoolByTopic` and `rankedWatchPool` are
  pre-computed properties on OrganizerStore, rebuilt only when the underlying
  data changes.

## Scraper-First Architecture

All read operations prefer scraping over the YouTube API:

| Operation | Primary (no quota) | Fallback (uses quota) |
|-----------|--------------------|-----------------------|
| Channel uploads | scrapetube / RSS feed | YouTube API (1-3 units/channel) |
| Video search | scrapetube.get_search | YouTube API (100 units/call) |
| Channel icons | Page scrape (youtube_channel_icons.py) | YouTube API (1 unit/50 channels) |
| Playlist add/remove | -- | YouTube API (50 units) |
| Not Interested | -- | Browser sync (no quota) |
| Watch Later | -- | Browser sync (no quota) |

Python scripts:
- `scripts/youtube_channel_fallback.py` — channel uploads via scrapetube/RSS
- `scripts/youtube_search_fallback.py` — video search via scrapetube
- `scripts/youtube_channel_icons.py` — avatar URLs by scraping channel pages

All scripts run in `.runtime/discovery-venv` with scrapetube installed.
Each process has a 30-second timeout to prevent hangs.

## Watch Pool & Ranking

After candidates are stored, the watch pool is built:

1. **Per-topic filtering**: `recentEligibleWatchVideos` filters to candidates
   published within the recency window (30 days)
2. **Excluded creators**: Channels the user has excluded are filtered out
3. **Topic assignment**: `assignWatchVideosToTopics` deduplicates videos that
   appear in multiple topics, assigning each to its strongest topic
4. **Reranking**: `rerankWatchVideos` applies:
   - Base score from discovery
   - Seen penalty (soft derank for app-seen videos)
   - Creator repeat penalty (prevents one channel from dominating)
   - Date tiebreaker (newer wins)

## Progress Reporting

- **Sidebar**: "23 Topics" becomes "Refreshing 3/23" with a mini spinner
  during refresh
- **Quota warning**: Orange "API Quota Exhausted" in toolbar when YouTube
  API quota is hit (scraper still works)
- **Completion**: When counter finishes, page is fully settled — all
  candidates and icons are cached

## Cancellation

- Switching from Watch to Saved cancels the refresh task
- The refresh loop checks `Task.isCancelled` each iteration
- Python scraper processes are terminated after 30 seconds

## Key Files

| File | Role |
|------|------|
| `OrganizerStore+CandidateDiscovery.swift` | Discovery orchestration, icon fetch, watch pools |
| `OrganizerStore.swift` | Watch pool materialization, state properties |
| `DiscoveryFallbackService.swift` | Python scraper interface (channels + search) |
| `CandidateDiscoveryCoordinator` | Ranking, topic assignment, admission gates |
| `scripts/youtube_channel_fallback.py` | Channel upload scraper |
| `scripts/youtube_search_fallback.py` | Video search scraper |
| `scripts/youtube_channel_icons.py` | Channel avatar scraper |

## Database Tables

| Table | Purpose |
|-------|---------|
| `topic_candidates` | Stored candidates per topic (top 36) |
| `candidate_sources` | Which source discovered each candidate |
| `candidate_state` | User actions: dismissed, saved, watched |
| `channel_discovery_archive` | Cached channel upload history |
| `channel_discovery_state` | Last scan timestamp per channel |
| `channels` | Channel metadata + icon_data blob |
| `seen_videos` | Watch history for deranking |
