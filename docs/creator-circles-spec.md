# Creator Circles: Per-Topic Channel Avatars with Filtering

## Overview

Add a row of circular channel avatars ("creator circles") at the top of each topic section. Each circle shows the creator's face/icon with metadata. Clicking a circle filters the topic's video grid to only that creator's videos. This gives users a fast visual way to browse by creator within any topic.

## Goals

- Surface creator identity prominently within each topic
- Enable one-click filtering to a specific creator's videos
- Aggressively cache all channel data locally to minimize YouTube API usage
- Normalize channel data into a dedicated table to eliminate duplication

## Current State

### What exists today

- **Videos table** stores `channel_name` and `channel_icon_url` denormalized per row
- **CreatorSectionHeaderView** is fully built (icon, name, count badge, topic pills, progress bar) but never instantiated in the view hierarchy
- **SortOrder.creator** exists in DisplaySettings but only sorts within sections — no visual creator grouping
- **TopicSection** has unused fields: `creatorName`, `channelIconUrl`, `topicNames`
- **OrganizerStore** already computes `channelCounts: [String: Int]` and has `moreFromChannel(videoId:limit:)`
- **YouTubeClient** already calls the `channels.list` endpoint for icon thumbnails and has batch fetching with rate-limit backoff

### What's missing

- No `channels` table — channel data is duplicated across every video row
- No `channel_id` on videos — creators are identified by string name (fragile)
- No locally cached icon image data — icons are fetched from URL on every render
- No UI for creator circles or click-to-filter behavior
- No channel-level metadata beyond name and icon URL

---

## Schema Changes

### New table: `channels`

```sql
CREATE TABLE channels (
    channel_id   TEXT PRIMARY KEY,   -- YouTube channel ID (e.g. "UC...")
    name         TEXT NOT NULL,
    handle       TEXT,               -- @handle if available
    channel_url  TEXT,               -- https://www.youtube.com/channel/{id}
    icon_url     TEXT,               -- source URL for re-fetching
    icon_data    BLOB,               -- locally cached icon image (JPEG/PNG bytes)
    subscriber_count TEXT,           -- formatted string from API
    description  TEXT,               -- channel description snippet
    video_count_total INTEGER,       -- total public videos on channel
    fetched_at   TEXT,               -- ISO8601 timestamp of last API fetch
    icon_fetched_at TEXT             -- ISO8601 timestamp of last icon download
);
```

### Migration on `videos` table

```sql
ALTER TABLE videos ADD COLUMN channel_id TEXT REFERENCES channels(channel_id);
```

### Backfill strategy

1. The existing `channel_icon_url` values contain the channel ID embedded in the YouTube thumbnail URL pattern (`yt3.ggpht.com/...`). Where possible, extract it.
2. For remaining videos, batch-fetch metadata via the YouTube `videos.list` API (already returns `channelId` in the snippet) and populate `channel_id` on the video row.
3. Deduplicate channel names — group videos by `channel_name`, resolve each to a single `channel_id`.
4. Populate the `channels` table from API responses.
5. Download and cache icon images into `icon_data`.

### Caching policy

- **Icon images**: Stored as BLOB in `icon_data`. Rendered from local bytes, never from URL at display time.
- **Staleness**: `fetched_at` and `icon_fetched_at` timestamps enable refresh-on-demand. Default: don't re-fetch unless explicitly requested or data is older than 90 days.
- **Source URLs preserved**: `icon_url` and `channel_url` kept so any cached data can be regenerated from source.
- **No implicit API calls on app launch** — all rendering uses cached data. Enrichment is a separate, user-triggered action.

---

## Data Layer Changes

### TopicStore additions

```swift
// New channel column expressions
private let channelId = SQLite.Expression<String>("channel_id")
private let channelTable = Table("channels")
// ... (all channel column expressions)

// New methods:
func createChannelsTable() throws
func upsertChannel(_ channel: ChannelRecord) throws
func channelById(_ id: String) -> ChannelRecord?
func channelsForTopic(id: Int64) -> [ChannelRecord]
func channelsForTopicIncludingSubtopics(id: Int64) -> [ChannelRecord]
func updateChannelIcon(channelId: String, iconData: Data) throws
func setVideoChannelId(videoId: String, channelId: String) throws
func videosMissingChannelId() -> [String]  // for backfill
func videosForTopicByChannel(topicId: Int64, channelId: String) -> [StoredVideo]
```

### New model

```swift
public struct ChannelRecord: Sendable, Identifiable {
    public let channelId: String
    public let name: String
    public let handle: String?
    public let channelUrl: String?
    public let iconUrl: String?
    public let iconData: Data?
    public let subscriberCount: String?
    public let description: String?
    public let videoCountTotal: Int?
    public let fetchedAt: String?
    public let iconFetchedAt: String?

    public var id: String { channelId }
}
```

### StoredVideo update

Add `channelId: String?` field to `StoredVideo`, populated from the new column.

### YouTubeClient additions

```swift
/// Fetch full channel details (snippet + statistics) for multiple channel IDs.
/// Returns ChannelRecord-ready data. Batches in groups of 50.
func fetchChannelDetails(channelIds: [String],
                         progress: ((Int, Int) -> Void)?) async throws -> [ChannelRecord]

/// Download channel icon image data from URL. Returns raw image bytes.
func downloadChannelIcon(url: URL) async throws -> Data
```

This reuses the existing `channels.list` endpoint but requests `part=snippet,statistics` instead of just `part=snippet`.

---

## OrganizerStore Changes

### New state

```swift
// Selected creator filter — nil means "show all creators"
var selectedChannelId: String?

// Cached channels per topic — rebuilt on loadTopics()
private(set) var topicChannels: [Int64: [ChannelRecord]] = [:]
```

### New methods

```swift
/// Returns channels that have videos in the given topic (including subtopics).
/// Sorted by video count descending within that topic.
func channelsForTopic(_ topicId: Int64) -> [ChannelRecord]

/// Returns video count for a specific channel within a topic.
func videoCountForChannel(_ channelId: String, inTopic topicId: Int64) -> Int

/// Toggle channel selection. If already selected, deselects (shows all).
func toggleChannelFilter(_ channelId: String)

/// Clear channel filter.
func clearChannelFilter()
```

### loadTopics() update

Rebuild `topicChannels` map alongside existing `videoMap` and `channelCounts` in `rebuildVideoMaps()`.

### Impact on filtering

`AllVideosGridView.recomputeFilteredSections()` gains a new filter stage: if `selectedChannelId != nil`, filter each section's videos to only those matching that channel ID.

---

## UI Changes

### 1. CreatorCirclesBar (new view)

Horizontal scrollable row of circular channel avatars, displayed between the topic section header and the video grid.

```
┌─────────────────────────────────────────────────────┐
│  Section Header: "Music Production"  (42 videos)    │
├─────────────────────────────────────────────────────┤
│  ◯ ◯ ◯ ◯ ◯ ◯ ◯ ◯ ◯  ···                          │
│  Creator circles (scroll horizontally)               │
├─────────────────────────────────────────────────────┤
│  ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐              │
│  │   │ │   │ │   │ │   │ │   │ │   │  Video grid   │
│  └───┘ └───┘ └───┘ └───┘ └───┘ └───┘              │
└─────────────────────────────────────────────────────┘
```

**Each circle shows:**
- Channel icon (from cached `icon_data` BLOB, falling back to SF Symbol `person.circle.fill`)
- Channel name below the circle (truncated if long)
- Video count badge (number of videos from this creator in this topic)

**Sizing:**
- Circle diameter: 44pt (default), scales with thumbnail size slider
- Name label: `.caption2`, single line, max width = circle diameter + 16pt
- Horizontal spacing: 12pt between circles

**Ordering:**
- Sorted by video count descending within the topic (most prolific creators first)
- If > ~15 creators, the row scrolls horizontally with a fade edge

**Interaction:**
- **Tap**: Selects the creator, adds a visible ring/highlight, filters videos below to only that creator
- **Tap again** (or tap a different creator): Deselects, shows all videos
- **Hover tooltip**: Shows full channel name, subscriber count, video count, and description snippet
- **Right-click context menu**: "Open Channel on YouTube" (opens `channel_url` in browser)

### 2. AllVideosGridView updates

In `sectionView()`, insert `CreatorCirclesBar` between the section header and the `LazyVGrid`:

```swift
@ViewBuilder
private func sectionView(_ section: TopicSection) -> some View {
    Section {
        // Existing: video grid
        // ...
    } header: {
        VStack(spacing: 0) {
            SectionHeaderView(/* existing */)
            CreatorCirclesBar(
                channels: store.channelsForTopic(section.topicId),
                selectedChannelId: store.selectedChannelId,
                topicId: section.topicId,
                onSelect: { store.toggleChannelFilter($0) }
            )
        }
    }
}
```

### 3. Filter state indicator

When a creator is selected:
- The selected circle gets a colored ring (accent color, 2pt stroke)
- A small dismissible chip appears below the circles: `"Showing: @creatorhandle (12 videos)"` with an ✕ to clear
- Video count in the section header updates to reflect the filtered count

### 4. CreatorSectionHeaderView (existing, repurposed)

The existing `CreatorSectionHeaderView` remains available for the `SortOrder.creator` mode, which groups videos into creator sub-sections. The new `CreatorCirclesBar` is a separate, always-visible component for filtering — not a replacement.

---

## Enrichment Flow

### When channels get populated

Channel enrichment is a separate step from video import, triggered explicitly:

1. **During metadata enrichment** (existing flow): `fetchAllVideoMetadata()` already returns `channelId` per video. After enrichment, for any new `channelId` not in the `channels` table:
   - Insert a stub row with just `channel_id` and `name` (from `channelTitle` in the video metadata response)
   - Queue for full enrichment

2. **Channel enrichment command** (new): Batch-fetches full channel details and icons for all stub/stale channels:
   ```
   video-tagger enrich-channels [--force] [--max-age-days 90]
   ```
   - Fetches `snippet` + `statistics` from `channels.list`
   - Downloads icon images and stores as BLOB
   - Respects rate limits using existing backoff logic

3. **On-demand in UI**: A "Refresh channel data" button in the sidebar or inspector that triggers enrichment for channels visible in the current topic.

### Backfill for existing databases

For databases that already have videos but no `channel_id`:

1. Run `videosMissingChannelId()` to find videos needing backfill
2. Batch-fetch video metadata (already cached `view_count` etc., but need `channelId`)
3. For videos with existing metadata, the `channelId` can be fetched via a lightweight `videos.list?part=snippet&fields=items(snippet/channelId)` call
4. Populate `channel_id` on video rows and create channel stubs
5. Run channel enrichment to fill in details and icons

---

## Edge Cases

| Case | Behavior |
|------|----------|
| Video has no `channel_id` yet | Excluded from creator circles; still shows in unfiltered grid |
| Channel has no cached icon | Show `person.circle.fill` SF Symbol with first letter of name |
| Topic has only 1 creator | Still show the circle row (single circle); no filtering needed but metadata is useful |
| Topic has 100+ creators | Horizontal scroll with fade edges; consider a "Show all" expansion |
| Creator selected, then topic changes | Clear `selectedChannelId` on topic navigation |
| Same creator appears in multiple topics | Each topic section shows its own circle independently; filter is per-topic |
| Channel renamed on YouTube | `fetched_at` staleness check catches this on next enrichment; local name updates |

---

## Files to Create or Modify

### New files
| File | Description |
|------|-------------|
| `Sources/VideoOrganizer/CreatorCirclesBar.swift` | New view: horizontal avatar row with selection |
| `Sources/TaggingKit/ChannelRecord.swift` | New model for channel data |

### Modified files
| File | Change |
|------|--------|
| `Sources/TaggingKit/TopicStore.swift` | Add `channels` table, migrations, channel CRUD, `channel_id` on videos |
| `Sources/TaggingKit/YouTubeClient.swift` | Add `fetchChannelDetails()`, `downloadChannelIcon()` |
| `Sources/VideoOrganizer/OrganizerStore.swift` | Add `selectedChannelId`, `topicChannels`, channel query methods, filter logic |
| `Sources/VideoOrganizer/AllVideosGridView.swift` | Insert `CreatorCirclesBar` in section headers, add channel filter to `recomputeFilteredSections()` |
| `Sources/TaggingKit/TopicStore.swift` (models) | Add `channelId` to `StoredVideo` |
| `Sources/VideoOrganizer/VideoGridItemModel` | Add `channelId` field |

### Unchanged
| File | Reason |
|------|--------|
| `CreatorSectionHeaderView.swift` | Kept as-is for `SortOrder.creator` mode; not part of this feature |
| `TopicSidebar.swift` | No sidebar changes needed for v1 |
| `VideoInspector.swift` | Could show channel details in future; not in scope |

---

## Implementation Order

1. **Schema**: Add `channels` table and `channel_id` column migration in `TopicStore`
2. **Model**: Create `ChannelRecord`, update `StoredVideo`
3. **Data methods**: Channel CRUD in `TopicStore`, channel queries in `OrganizerStore`
4. **API**: Add `fetchChannelDetails()` and `downloadChannelIcon()` to `YouTubeClient`
5. **Backfill**: Wire up channel enrichment in the CLI `enrich-channels` command
6. **UI**: Build `CreatorCirclesBar`, integrate into `AllVideosGridView`
7. **Filtering**: Add `selectedChannelId` state and filter logic

---

## Out of Scope (Future Work)

- Channel-level pages/detail views
- Cross-topic creator aggregation ("all videos by creator X across all topics")
- Creator-based topic suggestions ("you have 40 videos from this creator, create a topic?")
- Channel subscription status integration
- Creator circles in the sidebar
