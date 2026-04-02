# Navigation & Creator Discovery — Design Direction

## Current Architecture (shipped)

- **Sidebar**: Topic list with expandable subtopics, search with typeahead
- **Detail pane**: Video grid grouped by main topic sections with pinned headers
- **Inspector**: Video detail on hover/select, "More from channel" section
- **Toolbar**: Sort modes (Views, Date, Length, A-Z, Shuffle), inspector toggle

Subtopic click in sidebar filters grid to that subtopic's videos. Scroll sync highlights main topics only.

## Phase 1: Group by Creator (next)

Add "Group by Creator" as a sort/grouping mode in the existing toolbar. No new views or navigation.

**Canvas**: Videos grouped by channel name within each topic section. Creator group headers show:
- Channel icon (already have 88px thumbnails)
- Channel name
- Video count in this topic
- Total saved across all topics
- Subtopic distribution (which subtopics their videos appear in)

**Inspector**: When clicking a creator group header, inspector shows creator detail:
- Larger channel icon
- Video count breakdown by topic/subtopic
- Aggregate stats (total views, date range of saved content)

**Data source**: All derived from existing `videos` table. No API calls needed.

## Phase 2: Channel Stats Enrichment

Add a `channels` table with YouTube API data:

```sql
CREATE TABLE channels (
    channel_id TEXT PRIMARY KEY,
    name TEXT,
    icon_url TEXT,
    subscriber_count INTEGER,
    total_uploads INTEGER,
    created_at TEXT,
    fetched_at TEXT
);
```

**Data pipeline**:
1. Resolve channel IDs via `videos.list` API (batch 50 video IDs per call, ~48 calls, ~48 API units)
2. Fetch channel stats via `channels.list` API (batch 50 channel IDs per call, ~48 calls, ~48 units)
3. Total: ~100 API units, well under 10K daily free quota

**Freshness**: Auto-refresh monthly (check `fetched_at` on app launch). Manual "Refresh Now" action in app settings.

**Enables**:
- Head/mid/tail creator segmentation by subscriber count
- "New creator" badges (channel creation date)
- "Prolific" indicator (total uploads vs what you've saved)

## Phase 3: Creator Discovery

Fetch full upload playlists for followed/starred creators via `playlistItems.list` API.

**Enables**:
- "Unsaved videos from creators you watch" — videos they've published that aren't in your library
- Can be auto-classified into your existing topics using the tagger
- Discovery feed within a topic: "Creators you follow in this topic have 47 videos you haven't saved"

## Future Navigation Ideas (evaluated, not committed)

### Scope Bar (deferred)
Horizontal tab bar in detail pane: [My Videos] [Creators] [Discover]. Evaluated and rejected for now — premature before the features exist. Revisit when Discover is built and the content justifies a mode switch.

### Subtopic Chips (rejected)
Inline subtopic filter buttons below section headers. Rejected — competes with sidebar subtopics. One filtering system done well is better than two.

### Drill-In for Creator Detail (deferred)
NavigationStack push to a full creator page with back button. Considered for deep creator exploration (full video catalog, growth charts). Deferred — use inspector for now, promote to drill-in only if inspector space proves insufficient.

### Timeline View (future)
Visualization of a topic's evolution over time on YouTube. Would show publish dates, view velocity, trending moments. Requires absolute dates (currently stored as relative "1 year ago"). Would need API enrichment to get actual publish timestamps.

## Design Principles (from Apple design review)

1. **Don't build navigation for features that don't exist yet.** Ship the feature, then decide how to navigate to it.
2. **One way to do things, done well.** Avoid competing filter/navigation systems.
3. **What's the one thing?** Every screen has a primary action. The grid's primary action is browsing videos — creator info should surface within that flow, not alongside it.
4. **Ship the obvious version first.** Add complexity only when content and usage justify it.
5. **Drill-in for depth, tabs for breadth.** Don't mix the two metaphors.
