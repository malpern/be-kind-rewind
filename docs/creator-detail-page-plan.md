# Creator Detail Page Implementation Plan

## Goal

Build a full-screen creator detail page that lets the user browse, consume, and lightly analyze a single YouTube creator's body of work. The page replaces the current in-`VideoInspector` creator panel with a dedicated route that pushes onto the main content area's `NavigationStack`. It is shaped after Apple's own browse-detail conventions (Music.app artist page, App Store product page) and weights its content roughly **75% browse / discovery / consumption** and **25% niche / topic / cadence analytics**.

The page is reached by clicking a creator's name from:
- A video card or row in `CollectionGridView`
- The creator name in `VideoInspector`
- A creator avatar in `CreatorCirclesBar`

## Why this is worth building

The app already collects rich data about creators (`channels` table, `archivedVideosForChannels`, `playlistsByVideoId`, saved videos by topic) but the only place that surfaces a per-creator view today is the right-hand `VideoInspector`, which is too cramped for real investigation. A dedicated detail page turns the existing data into an actual destination for "learn about this creator" workflows: deciding whether to follow them, exploring what they make, finding their best work, understanding which topics they own, and discovering similar creators worth watching.

The plan also lays a small but high-leverage analysis foundation: **outlier scoring** as a reusable module starting in Phase 1. This single primitive — "is this video punching above the creator's normal performance?" — is the most-cited feature across the entire YouTube research-tools category (vidIQ, 1of10, TubeBuddy, Morningfame) and costs essentially nothing to compute on data we already have. It improves Essentials selection in Phase 1, drives a "their hits" section and title pattern extraction in Phase 3, and powers per-topic and library-wide outlier feeds in Phase 4. See Appendix D for the research that informed this decision.

## Design references and the 75/25 framing

This plan was refined through three rounds of design research. The relevant takeaways:

- **Apple's App Store and Music.app artist page are the right reference frame**, not Spotify/Letterboxd/Last.fm web apps. macOS users have deep muscle memory for Apple's browse-detail page shape.
- The native shape is consistent across App Store, Music, TV, Podcasts, News, Books: **identity card → highlight → curated essentials → full catalog → related → context → analytics → similar → information**.
- The 75/25 split falls out naturally from following that shape — the analytics block is one compact section near the bottom, not a competing visual surface.
- Apple's two patterns most worth stealing for this page:
  1. **Essentials + Full catalog**: a curated short list as a separate section above the complete list. Music.app's "Essential Albums" + "Albums" is the model.
  2. **What's New as a tiny dedicated callout**: a single most-recent item shown prominently, separate from the full history. App Store + Music both do this.

The 75/25 ratio is a target, not a hard gate. In practice the analytics surface is one `GroupBox` near the bottom containing two SwiftUI Charts. Everything else is browse / consume.

## Layout reference (ASCII)

The detail page enters with the sidebar **auto-collapsed** to `.detailOnly`. The toolbar's standard `NavigationSplitView` sidebar toggle remains available so the user can bring the sidebar back at any time with `⌘0`. The inspector column on the right is still available for video selection drill-down. The default appearance is below:

```
╭──────────────────────────────────────────────────────────────────────────────────────╮
│ ●●●  [☰] ◀ ▶ ┃ Mech Kbds › Hipyo Tech    [📌 Pin] [⊘ Exclude] [↗ YouTube] [ⓘ]        │
├───────────────────────────────────────────────────────────────────┬──────────────────┤
│                                                                   │ INSPECTOR        │
│  ╭─────╮ Hipyo Tech                                                │                  │
│  │ AVA │ Mechanical kbds · custom builds · reviews                 │ Select a video   │
│  │     │ small creator · since 2017 · United States                │ to see details.  │
│  ╰─────╯ 247 saved · 89 watched · 1.2M subs · last upload 3d       │                  │
│ ────────────────────────────────────────────────────────────────── │                  │
│                                                                    │                  │
│  What's new                                                        │                  │
│  ┌──────────────────────────────────────────────────────────────┐  │                  │
│  │ ▢▢▢▢▢   I tried the new Lily58 layout for a week              │  │                  │
│  │ ▢▢▢▢▢   3d · 142K views · 12:34                  [▶ Play]    │  │                  │
│  └──────────────────────────────────────────────────────────────┘  │                  │
│                                                                    │                  │
│  Essentials                                                        │                  │
│  ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮  →               │                  │
│  │▢▢▢▢▢│ │▢▢▢▢▢│ │▢▢▢▢▢│ │▢▢▢▢▢│ │▢▢▢▢▢│ │▢▢▢▢▢│                 │                  │
│  │Lily↑│ │Why I│ │Switch│ │Best │ │My ne│ │Hot↑ │                  │                  │
│  │8.4× │ │5.1× │ │3.7× │ │3.1× │ │2.4× │ │6.0× │                  │                  │
│  ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯                  │                  │
│                                                                    │                  │
│  All videos                                          [Sort ▾]      │                  │
│  ┌──────────────────────────────────────────────────────────────┐  │                  │
│  │ #  │     │ Title                  │ Topic    │ Views │ Age   │  │                  │
│  ├────┼─────┼────────────────────────┼──────────┼───────┼───────┤  │                  │
│  │ 1  │ ▢▢ │ I tried Lily58... ↑    │ Mech Kbd │ 1.2M  │ 3d    │  │                  │
│  │ 2  │ ▢▢ │ Hot takes on linears ↑ │ Mech Kbd │ 488K  │ 9mo   │  │                  │
│  │ 3  │ ▢▢ │ Why I switched...      │ Mech Kbd │ 890K  │ 2mo   │  │                  │
│  │ 4  │ ▢▢ │ Switch chemistry...    │ Mech Kbd │ 745K  │ 4mo   │  │                  │
│  │ … │                                                          │  │                  │
│  └──────────────────────────────────────────────────────────────┘  │                  │
│  ↑ = punching above this creator's median (outlier)                │                  │
│                                                                    │                  │
│  In your playlists                                                 │                  │
│  ┌──────────────────────────────────────────────────────────────┐  │                  │
│  │ ♫  Best builds 2024              7 videos      ▸             │  │                  │
│  │ ♫  Switch reviews                4 videos      ▸             │  │                  │
│  │ ♫  Watch later                   3 videos      ▸             │  │                  │
│  └──────────────────────────────────────────────────────────────┘  │                  │
│                                                                    │                  │
│  ┌─ Niches & cadence ─────────────────────────────────────────┐    │                  │
│  │ Topic share              Videos / month (24mo)             │    │                  │
│  │ Mech Kbds  ████████ 78%   ▆ ▇ █ █ ▇ █ █ ▆ ▅ ▆ █ █          │    │                  │
│  │ Tech Gad   ██ 14%         █ ▇ █ █ █ ▆ ▆ █ ▇ █ █ █          │    │                  │
│  │ Other      █ 8%                                             │    │                  │
│  └─────────────────────────────────────────────────────────────┘    │                  │
│                                                                    │                  │
│  Channel information                                               │                  │
│  ┌──────────────────────────────────────────────────────────────┐  │                  │
│  │ Subscribers          1.2M                                    │  │                  │
│  │ Total uploads        347                                     │  │                  │
│  │ In your library      247 (71%)                               │  │                  │
│  │ Channel created      Jun 14, 2017                            │  │                  │
│  │ Country              United States                           │  │                  │
│  │ Last refreshed       2026-04-10 09:51 PT                     │  │                  │
│  │ YouTube              youtube.com/@hipyotech              ↗   │  │                  │
│  └──────────────────────────────────────────────────────────────┘  │                  │
╰────────────────────────────────────────────────────────────────────┴──────────────────╯
```

The `[☰]` button at the top-left of the toolbar is the standard `NavigationSplitView` sidebar toggle — `⌘0` brings the topic sidebar back if the user wants it. The `↑` markers on Essentials cards and All Videos rows indicate **outlier scores** (videos punching above this creator's median view count), with the multiplier (e.g. `8.4×`) showing how far above baseline.

## Current state — what already exists

The exploration confirmed that **roughly 70% of the data is already in memory** when a creator name is clicked. Reuse rather than reinvent.

### Models
- `ChannelRecord` (`Sources/TaggingKit/ChannelRecord.swift:4`) — `channelId`, `name`, `handle`, `channelUrl`, `iconUrl`, `iconData`, `subscriberCount`, `description`, `videoCountTotal`, `fetchedAt`, `iconFetchedAt`.
- `CreatorDetailViewModel` (`Sources/VideoOrganizer/OrganizerViewModels.swift:356`) — already aggregates total saved videos, total views, age range, recent-30-day count, subscriber count, total uploads, and a per-topic breakdown.
- `ArchivedChannelVideo` (`Sources/TaggingKit/...`) — discovered videos beyond what the user has saved.

### Analytics
- `CreatorAnalytics.makeCreatorDetail(for channelName:)` (`Sources/VideoOrganizer/OrganizerStore+CreatorAnalytics.swift:11`) — populates `CreatorDetailViewModel`. **Currently keyed by `channelName` (string match), which is fragile and must be migrated to `channelId` as part of Phase 1.**
- `parseViewCount`, `parseAge`, `formatAge`, `parseISO8601Date` — utility functions for working with both scrape (fuzzy) and API (canonical) data shapes.

### Existing creator views
- `VideoInspector.swift:324` — the current creator detail rendering inside the right inspector panel. This is what we are replacing with a full page route.
- `CreatorCirclesBar.swift` — horizontal scrollable row of channel avatars with click-to-filter, used inside the topic grid.
- `inspectedCreatorName: String?` (`OrganizerStore.swift:79`) — the existing "creator inspection mode" state machine.

### Existing creator actions
- `applyChannelFilter(channelId:)` / `toggleChannelFilter` / `clearChannelFilter` (`OrganizerStore.swift:625`) — filters the topic grid by creator.
- `navigateToCreator(channelId:channelName:preferredTopicId:)` (`OrganizerStore.swift:772`) — navigates to a topic where the creator appears.
- `excludeCreatorFromWatch(channelId:channelName:iconUrl:)` (`OrganizerStore+VideoActions.swift:19`) — adds to `excluded_channels`, used for hiding from Watch.
- `restoreExcludedCreator(channelId:)` (`OrganizerStore+VideoActions.swift:60`).
- `moreFromChannel(videoId:limit:)` (`OrganizerStore.swift:533`) — recent videos from the same channel.

### Per-topic and per-channel data
- `topicChannels: [Int64: [ChannelRecord]]` (`OrganizerStore.swift:571`) — channel cache per topic, rebuilt on `loadTopics()`.
- `videosForTopicByChannel(topicId, channelId)` (`TopicStore.swift:701`) — saved videos for a channel within a topic.
- `videosForTopicIncludingSubtopics(topicId)` — used by current `CreatorAnalytics`.
- `archivedVideosForChannels([channelId], perChannelLimit:)` — discovery archive (~16-24 most recent uploads per channel).
- `playlistsByVideoId: [String: [PlaylistRecord]]` (`OrganizerStore.swift:568`) — full playlist memberships, rebuilt on `loadTopics()`.

### LLM infrastructure
- `ClaudeClient` (`Sources/TaggingKit/ClaudeClient.swift`) — Haiku/Sonnet client, reads keys from keychain / env / config file.
- `TopicSuggester` (`Sources/TaggingKit/TopicSuggester.swift`) — established pattern for batched JSON-only Claude classification. Reusable for theme clustering in Phase 2.

### Navigation patterns
- `NavigationSplitView` with sidebar and detail column.
- `QuickNavigatorView` (`Sources/VideoOrganizer/QuickNavigatorView.swift`) — recent example of a sheet-based navigation surface, useful as a reference for binding patterns and `@Bindable`.
- The detail column does not currently use a `NavigationStack` for push navigation — we will need to introduce one to support pushing creator detail and walking back.

## Two structural fixes required before building

### 1. Migrate `CreatorAnalytics` to use `channelId`, not `channelName`

`CreatorAnalytics.makeCreatorDetail(for: channelName)` currently filters by string equality on `channelName`. This breaks under:
- channel renames
- two channels sharing a display name

The page is keyed off creator identity, so the canonical key has to be `channelId`. The migration is small but a prerequisite:

- Add `creatorDetail(channelId: String) -> CreatorDetailViewModel` as the primary entry point.
- Internally filter videos by `video.channelId == channelId`.
- Keep the `channelName`-based variant for backwards compatibility for one release; deprecate.
- Update `VideoInspector`, `CreatorCirclesBar`, and `navigateToCreator` to thread `channelId` through.

### 2. Introduce a `NavigationStack` in the detail column **and auto-collapse the sidebar on entry**

The current detail column hosts a single view (`OrganizerView`'s grid). The creator page should follow the **Photos.app / Music.app detail page pattern**: when entering the page, the central content area takes over and the sidebar slides away into `.detailOnly` visibility. The toolbar's automatic sidebar toggle (provided by `NavigationSplitView`) lets the user bring the sidebar back at any time with `⌘0`, but the default state during a detail page visit is sidebar-collapsed for focus.

Two pieces of plumbing:

1. **Wrap the detail column in `NavigationStack`.** Navigating to a creator page is `path.append(.creator(channelId))` and back is automatic via the standard navigation back button.
2. **Drive `NavigationSplitView` column visibility from a `@State` binding.** On detail page push, set `columnVisibility = .detailOnly`. On back-navigation (`path` becomes empty or pops back to the topic root), restore `columnVisibility = .all` or whatever the user's last preference was. ~10 lines of plumbing total.

This is **not** a `.fullScreenCover` and is **not** a separate window — both were considered and rejected. It is a native `NavigationSplitView` columnVisibility transition combined with a NavigationStack push, which is exactly how Apple's own apps handle the same problem.

Risk: introducing the navigation stack changes the grid view's hosting, which has historically been sensitive to scroll restoration and selection state. Phase 1 should test grid scroll persistence under `NavigationStack` carefully. The auto-collapse of the sidebar is purely additive — if it causes any issue we can ship the navigation stack alone first and add the sidebar collapse in a follow-up commit. **Fallback if the navigation stack itself regresses the grid:** present `CreatorDetailView` as a `.fullScreenCover` (less ideal but functional). The sidebar auto-collapse is irrelevant in that fallback case.

## Phase 1 — MVP

**Scope:** Build the page with everything that is free or near-free using existing data. No LLM calls. No new scrapes. One small new persistence table (`favorite_channels`).

### In scope

- New `CreatorDetailView` SwiftUI view.
- New `CreatorPageViewModel` aggregating the data the page needs (richer than the existing `CreatorDetailViewModel`).
- Refactor `CreatorAnalytics` to be `channelId`-keyed.
- `NavigationStack` introduced in the detail column; `CreatorDetailView` pushed onto it.
- New `favorite_channels` table mirroring `excluded_channels`.
- New `favoriteCreator(channelId:)` / `unfavoriteCreator(channelId:)` actions in `OrganizerStore`.
- Toolbar buttons: Pin, Filter, Exclude, Open in YouTube. Replace any in-page action buttons.
- Keyboard shortcuts: `⌘[` back, `↩` play selection, `⌘↩` open in YouTube.
- Right-side `VideoInspector` continues to work for selection-driven detail.

### Sections to build (Phase 1)

| # | Section | Source | Component |
|---|---|---|---|
| 1 | Identity card | `CreatorPageViewModel` (channel record + computed chips). Subtitle pulled from channel description for now. | `HStack` of avatar + metadata `VStack` |
| 2 | What's new | Most recent video from saved+archive merge for this `channelId` | Custom row, ~100pt tall |
| 3 | Essentials | Top 6-8 videos by **outlier score** (`OutlierAnalytics.topOutliers`), recency-weighted. Inline `↑` badge on cards that are outliers | `LazyHGrid` inside horizontal `ScrollView` |
| 4 | All videos | Full saved + archive merge, sorted by user choice. Outlier rows display a small `↑` badge in the title cell | `Table` with columns: #, thumbnail, title, topic, views, runtime, age |
| 5 | In your playlists | `playlistsByVideoId` filtered to videos by this `channelId` | Grouped `List` |
| 6 | Niches & cadence | Topic distribution (% by topic) + monthly publish histogram (24 months) | `GroupBox` with two `Charts` side by side |
| 7 | Channel information | Channel record + computed stats | 2-column `Form` or `Grid` at the bottom |

**Deferred to later phases**: themes (LLM), about paragraph (LLM), creators you might like (Phase 2), full upload backfill (Phase 3).

### Out of scope for Phase 1

- LLM theme clustering.
- LLM-generated about paragraph.
- "Creators you might like" similarity section.
- Loading uploads beyond what's already in the archive.
- Compare two creators side by side.
- Creator notes field (Phase 3).
- Cross-creator analytics (e.g. dominance ranking).
- Per-creator new-uploads-since-last-visit indicator.

### Data model changes (Phase 1)

#### New table: `favorite_channels`

```sql
CREATE TABLE favorite_channels (
    channel_id TEXT PRIMARY KEY,
    channel_name TEXT NOT NULL,
    icon_url TEXT,
    favorited_at TEXT NOT NULL,    -- ISO8601
    notes TEXT                      -- free text, Phase 3 field but cheap to add now
);
```

Mirrors the `excluded_channels` shape so the same persistence patterns apply.

#### New view model

```swift
struct CreatorPageViewModel {
    let channelId: String
    let channelName: String
    let subtitle: String?              // first sentence of channel description
    let avatarData: Data?
    let avatarUrl: URL?
    let creatorTier: String?           // small/growing/mid-tier/large/mega
    let foundingYear: Int?             // from oldest known publish date
    let country: String?               // if available

    // Header chips
    let savedVideoCount: Int
    let watchedVideoCount: Int          // from seenSummary
    let subscriberCountFormatted: String?
    let lastUploadAge: String?

    // What's new
    let latestVideo: VideoCardViewModel?

    // Outlier baseline used by the page; surfaced for tooltips/debugging
    let channelMedianViews: Int

    // Essentials (curated 6-8 by outlier score)
    let essentials: [VideoCardViewModel]

    // All videos
    let allVideos: [VideoCardViewModel]      // saved + archive merged

    // Playlists this creator appears in
    let playlists: [(playlist: PlaylistRecord, videoCount: Int)]

    // Niche fingerprint
    let topicShare: [(topicName: String, count: Int, percentage: Double)]

    // Cadence
    let monthlyVideoCounts: [(month: Date, count: Int)]   // last 24 months

    // Information
    let channelCreatedDate: Date?
    let totalUploadsKnown: Int            // from channel record OR archive count
    let coveragePercent: Double?          // saved / total uploads
    let lastRefreshedAt: Date?
    let youtubeURL: URL
    let isFavorite: Bool
    let isExcluded: Bool
}

struct VideoCardViewModel {            // Phase 1 inline; promote to file when needed
    let videoId: String
    let title: String
    let thumbnailUrl: URL?
    let topicName: String?
    let viewCountFormatted: String
    let runtimeFormatted: String?
    let ageFormatted: String
    let isSaved: Bool
    let savedTopicId: Int64?
    let playlists: [PlaylistRecord]
    let outlierScore: Double               // views / channelMedianViews
    let isOutlier: Bool                    // outlierScore >= 3.0 by default
}
```

This is a richer aggregate than the existing `CreatorDetailViewModel`. We **keep** `CreatorDetailViewModel` for the inspector use case and add `CreatorPageViewModel` as the page-level aggregate. They can share a builder.

#### New builder

`CreatorPageBuilder.makePage(for: channelId, in: store) -> CreatorPageViewModel` in a new file `Sources/VideoOrganizer/OrganizerStore+CreatorPage.swift`. Reuses the existing topic-channels cache, archive, and playlist maps. Should be cheap (no async, no LLM, no network).

### Selection of "Essentials" — outlier-first scoring

After researching how vidIQ, 1of10, TubeBuddy, and Morningfame approach this exact problem (see Appendix D), the consensus across the YouTube research-tools category is unambiguous: **rank by outlier score, not raw views.** A 1M-view video on a 5M-average channel is normal; a 1M-view video on a 100k-average channel is a signal worth surfacing. Raw "most viewed" hides the second case entirely and makes Essentials feel obvious instead of insightful.

Phase 1 adopts the outlier-first algorithm directly. The math is simple, dependency-free, and runs entirely in memory on data we already have:

```
medianViews = median(viewCount across all known videos for this channel)
            // robust to outliers; falls back to mean when N < 6

outlierScore(v)  = v.views / max(medianViews, 1)
recencyWeight(v) = 1.0  if ageDays(v) <= 365
                   0.75 if ageDays(v) <= 730
                   0.5  otherwise

essentialsScore(v) = outlierScore(v) * recencyWeight(v)
```

Take the top 8 by `essentialsScore`. Tiebreaker: raw view count.

**Why this is better than the original log+recency formula:**
- Surfaces videos that *punched above the creator's normal performance*, not just their biggest channels overall.
- Naturally adapts to creators of different sizes — a small creator's outlier and a huge creator's outlier are scored on the same axis.
- Mild recency weighting keeps stale viral hits from dominating forever, but doesn't punish good evergreen work.
- Free to compute. No new API spend, no LLM, no persistence — just statistics over existing view counts.

**Edge cases:**
- Fewer than 6 known videos: median is meaningless. Fall back to raw view count sort and skip Essentials section if < 6 videos.
- All views null: rank by recency only.
- Single dominant outlier: cap individual `outlierScore` at, say, 50× to prevent one freak hit from drowning the rest of the list.

### Outlier scoring as a reusable module

Outlier scoring is the single highest-leverage analysis primitive in the entire research-tool category, and we get it almost for free. Phase 1 introduces it as a small dedicated module that the creator detail page consumes, but the same module is reused across the app from day one:

- **`Sources/VideoOrganizer/OutlierAnalytics.swift`** (new) — pure functions, no state. Computes:
  - `channelMedianViews(videos: [...]) -> Int`
  - `outlierScore(video:, channelMedian:) -> Double`
  - `topOutliers(videos: [...], limit: Int) -> [...]` — used by Essentials
  - `isOutlier(video:, channelMedian:, threshold: Double = 3.0) -> Bool` — used by the All Videos table to badge punching-above-weight rows

- **All Videos table** gains a small visual badge (◉ or `↑`) next to titles where `isOutlier(...) == true`. No new column — the badge sits inline with the title cell.

- **Topic grid (Phase 1, low-risk)** — optionally extend `CollectionGridView` to show the same badge on cards across the app. This is a single-line check inside the existing card renderer and gives users the same outlier signal everywhere a video appears.

The reusability is the point: building outlier scoring once for Essentials lets us light up the same insight in every other surface that displays videos, including the topic grid, the inspector, and the Watch refresh ranking, without re-implementing the math.

### Component inventory

| Section | SwiftUI primitive | Notes |
|---|---|---|
| Page root | `ScrollView` containing `LazyVStack(spacing: 24)` | Vertical scroll, lazy sections |
| Identity card | `HStack` + `VStack` | Avatar via `AsyncImage` with fallback to cached `iconData` |
| What's new | Custom row, plain `HStack` inside a `Section` | Click → inspector |
| Essentials | `ScrollView(.horizontal)` containing `LazyHGrid(rows: [GridItem(.fixed(160))])` | Card width ~140pt, height ~160pt |
| All videos | `Table` with sortable `TableColumn`s | Selection drives inspector via `NavigationLink`/`@State selection` |
| In your playlists | `List { Section { ForEach(...) } }` | Right-chevron rows |
| Niches & cadence | `GroupBox("Niches & cadence")` containing `HStack { Chart {...}; Chart {...} }` | Use SwiftUI Charts |
| Channel information | `Grid` or `Form { Section { LabeledContent } }` | 2 columns |
| Section headers | `Section { ... } header: { Text(...).font(.title2.weight(.semibold)) }` with `.headerProminence(.increased)` | Native typography |
| Toolbar | `.toolbar { ToolbarItemGroup(placement: .primaryAction) { ... } }` | Pin / Exclude / YouTube / Info |

### Header surface

Use a Liquid Glass material for the identity card background on macOS 26 (`swiftui-liquid-glass` skill available). Falls back to `.regularMaterial` on earlier OS versions. The header should feel like a tasteful card that separates from the scrollable content but does not visually compete with it.

### Inspector behavior

Selecting a row in the All Videos table or a card in Essentials should populate the existing right-side `VideoInspector` with that video's details. The page itself does not need to render any video detail — that's the inspector's job. This matches Mail/Music/TV.

### Navigation entry points

| Origin | Trigger | Action |
|---|---|---|
| `CollectionGridView` row creator name | Click | Push `CreatorDetailView(channelId)` |
| `VideoInspector` creator name | Click | Push `CreatorDetailView(channelId)` |
| `CreatorCirclesBar` avatar | `⌥`-click or right-click → "Open Creator Page" | Push (default click still applies channel filter) |
| Quick navigator (future) | Type a creator name | Push |

### Toolbar contents

Replace the in-page header buttons with toolbar items:

| Item | Symbol | Action |
|---|---|---|
| Pin | `pin` / `pin.fill` | Toggle `favoriteCreator(channelId)` |
| Filter saved | `line.3.horizontal.decrease.circle` | Pop back to topic, apply channel filter |
| Exclude | `nosign` | Toggle `excludeCreatorFromWatch` |
| Open in YouTube | `arrow.up.right.square` | Open `youtubeURL` in default browser |

The window's existing back button (provided automatically by the `NavigationStack`) handles "go back" and there's no need for a custom back button.

### Phase 1 polish (deferred — surfaced during manual testing)

Items captured during the Phase 1 manual testing pass that aren't blocking but should land before Phase 2 ships. They build on the Phase 1 view structure with no new persistence or LLM dependencies.

#### Recent uploads grid (replaces single "What's new" row)

The current Phase 1 implementation shows exactly one video in the "What's new" section — the most recent upload. This is wrong for any creator who drops multiple videos in a short window (a Build Vlog series running daily, a creator's batch release, etc.). The 2nd and 3rd recent videos get hidden until the user scrolls to the All Videos table.

**Replacement:** A bounded recent-uploads section keyed off a 14-day window, rendered using the same **grid styling as the main collection grid** (`CollectionGridView` cards), not a stacked-row treatment.

| Recent uploads in window | Render |
|---|---|
| 0 in window | Show the single most recent video as a grid card (fallback) |
| 1 in window | Show that one video as a single grid card |
| 2-5 in window | Show all of them as a grid row |
| 6+ in window | Show first 5 with a small `+ N more` link that scrolls to the All Videos table |

Section header copy adapts:
- 1 item: `What's new`
- 2+ items: `Recent uploads · last 14 days`

**Implementation notes:**
- Replace `latestVideo: CreatorVideoCard?` on `CreatorPageViewModel` with `recentVideos: [CreatorVideoCard]` (always non-empty when the creator has any video).
- Builder filters `allVideos` by `ageDays <= 14` and caps at 5; falls back to the single most recent when the window is empty.
- The section view uses the same `VideoGridItem` (or its underlying card primitive) that `CollectionGridView` uses, so the visual treatment matches the rest of the app.

**Open question:** if `VideoGridItem` is tightly coupled to `CollectionGridAppKit` and not directly reusable from a SwiftUI parent, we may need to extract a small reusable card view. Worth ~30 minutes of investigation before committing to the approach.

## Phase 2 — Themes, About, similar creators, search, and tag navigation

**Scope:** LLM-powered enrichments + the navigation features the user requested during Phase 1 manual testing. New persistence for LLM caching so we are not paying per page-open.

### In scope — LLM enrichments

- `CreatorThemeClassifier` — batch Claude Haiku call that takes ~200 video titles for a creator and returns 5-10 named clusters with descriptions and member video IDs.
- `creator_themes` SQLite table for caching results.
- "By theme" section in `CreatorDetailView` using `OutlineGroup` / `DisclosureGroup`.
- Series detection regex pre-pass for patterns like "Episode N", "Day N", "Part N" — cheaper and more accurate than LLM for the recurring-title case.
- "About" paragraph generated by Haiku from the title sample, ~3-5 sentences. Cached in `creator_about` table.
- New Settings toggle: "Enable Claude theme classification" (default off), mirroring the API search fallback toggle pattern.
- Cost surfaced in the existing telemetry / Settings panel.

### In scope — navigation and discovery (added during Phase 1 manual testing)

These items expand the creator detail page's research surface. They were requested while exercising Phase 1 in the running app and are grouped here because they share the LLM theme infrastructure introduced in this phase.

#### Tag capsules from LLM themes

Once `CreatorThemeClassifier` is producing themes, surface them on the creator detail page as a **horizontal row of capsule-style filter chips with counts** above the All Videos table. Examples:

```
[Build vlogs · 12]  [Switch reviews · 8]  [Tutorials · 5]  [Hot takes · 3]  ...
```

Clicking a capsule filters the All Videos table to videos in that theme. Multi-select (cmd-click) is supported. A "Clear" capsule appears when any filter is active. The capsules sit between the Essentials shelf and the All Videos table so they're discoverable but don't compete with the curated picks above.

This is the user's "tag navigation" request — the LLM theme clusters become a first-class navigation surface, not just a separate "By theme" section.

#### Per-creator search box

A search field at the top of the All Videos section that filters the table to titles matching the query. Scoped to **this creator only** — distinct from the main app search (which spans the whole library). Lives inline above the All Videos table, not in the toolbar:

```
All videos                          [⌕ Search this creator's videos        ]   [Sort ▾]
```

Implementation:
- New `@State` `creatorSearchText: String = ""` on `CreatorDetailView`.
- Filter `page.allVideos` by case-insensitive title match before passing to the `Table`.
- Combines with tag-capsule filtering — if both are active, both apply (intersection).
- Cleared on navigation away from the page.

#### `from:` advanced search syntax (main app search)

A new operator on the main app's search input: `from:CreatorName` narrows results to videos from a specific creator across the entire library. Mirrors the existing `topic:` and `playlist:` operators if they exist (need to check), or introduces the operator pattern if not.

Examples:
- `from:Hipyo` → all saved videos by Hipyo Tech (substring match on channel name)
- `keyboard from:Hipyo` → keyboard-related videos by Hipyo Tech only
- `from:"Studio No Ha"` → exact phrase match for creators with spaces in their names

This is a main-app feature, not a creator-detail-page feature, but it's queued here because the user requested it in the same conversation. Implementation lives in `OrganizerStore` parsed-query handling and the `TopicSidebar` / `OrganizerView` search field. May warrant being split into its own small commit and shipped independently of the creator detail page work.

#### Competitor leaderboard (replaces the Phase 2 "Creators you might like" section)

The user explicitly asked for a **leaderboard-style** competitor view on the creator page, scoped to creators currently tracked in their library. This supersedes the original Phase 2 "Creators you might like" / Spotify "Fans Also Like" framing — the user wants ranking, not affinity discovery.

Section design:

```
Top creators in this niche                                  [scope: top topic ▾]

  1.  [avatar] Hipyo Tech              247 saved · 1.2M subs · 89 outliers   ▸
  2.  [avatar] TaehaTypes               89 saved · 410K subs · 32 outliers   ▸
  3.  [avatar] Switch & Click            71 saved · 220K subs · 24 outliers   ▸
  4.  [avatar] Hipyo Tech              ...
  5.  ...
```

Ranking criteria (tunable, default to "saved videos in shared topics"):
- **By saved count**: how many videos from each creator are in the topics this creator publishes in
- **By outlier count**: how many videos in shared topics qualify as outliers (uses Phase 1 `OutlierAnalytics`)
- **By total views**: sum of parsed view counts in shared topics

The "scope" picker at the top lets the user pick which topic the leaderboard is computed against (default: this creator's primary topic). Click any row to push that creator's detail page onto the navigation stack — chained creator browsing.

Computed entirely from existing library data plus `OutlierAnalytics`. No new API spend, no LLM required (though the topic share data feeding it does benefit from LLM-derived themes if they're available).

This is more analytical than the original "Creators you might like" framing and fits the user's curator/research mindset better than the discovery framing.

### Cost discipline (LLM)

- Use Haiku, never Sonnet, for theme classification.
- Cap input to 200 titles per run.
- Run once per creator, cached forever.
- Re-run only when:
  - the creator gains > 20 new videos since last classification, OR
  - the user explicitly hits "Refresh themes".
- Estimated cost: $0.001 to $0.005 per creator.
- Display total spent in Settings → YouTube Quota panel (extend to a "Claude usage" sub-section).

### Data model changes (Phase 2)

```sql
CREATE TABLE creator_themes (
    channel_id TEXT NOT NULL,
    theme_label TEXT NOT NULL,
    theme_description TEXT,
    theme_order INTEGER NOT NULL,
    video_ids TEXT NOT NULL,         -- JSON array
    classified_at TEXT NOT NULL,
    classified_video_count INTEGER NOT NULL,
    PRIMARY KEY (channel_id, theme_label)
);

CREATE TABLE creator_about (
    channel_id TEXT PRIMARY KEY,
    summary TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    source_video_count INTEGER NOT NULL
);
```

The per-creator search box, tag capsules (which read from `creator_themes`), competitor leaderboard, and `from:` syntax all add **no new persistence** — they're pure transforms over data already in memory or in the existing tables.

### File deliverables (Phase 2)

New files:
- `Sources/TaggingKit/CreatorThemeClassifier.swift` — the Haiku batch call.
- `Sources/VideoOrganizer/CreatorThemeCapsuleBar.swift` — the horizontal capsule filter row.
- `Sources/VideoOrganizer/CreatorLeaderboardSection.swift` — the competitor leaderboard view.

Modified files:
- `Sources/TaggingKit/TopicStore.swift` — add `creator_themes`, `creator_about` tables and CRUD.
- `Sources/VideoOrganizer/CreatorPageViewModel.swift` — add `themes`, `about`, `leaderboardEntries`, and `recentVideos` (Phase 1 polish item) fields.
- `Sources/VideoOrganizer/CreatorPageBuilder.swift` (or extension) — populate themes/about from the cache, build leaderboard from topic share + outlier analytics.
- `Sources/VideoOrganizer/CreatorDetailView.swift` — add tag capsule bar, per-creator search box, themes section, leaderboard section, recent uploads grid (Phase 1 polish item).
- `Sources/VideoOrganizer/OrganizerStore.swift` (or query parser file) — add `from:` operator to the existing parsed-query handling. If no parsed-query infrastructure exists today, this commit introduces it as a small, focused module that can later host other operators.
- `Sources/VideoOrganizer/AppSettingsView.swift` — add the "Enable Claude theme classification" toggle.

### Out of scope for Phase 2

- Cross-creator clustering ("which 5 channels in your library are most similar").
- Topic evolution over time (reserved for Phase 3).
- Manual theme curation / editing.
- Manual leaderboard scope override (the user explicitly pinning competitors) — Phase 3.

## Phase 3 — Deep history, favorites, per-creator niche analysis

**Scope:** Polish, deeper history, using the favorite_channels signal to influence Watch refresh, and adding per-creator niche analysis features informed by the YouTube research-tools survey (see Appendix D).

### In scope — history & polish

- "Load full upload history" button on the page → triggers a one-time deeper scrape of the channel via `youtube_channel_fallback.py --max-results 200`. Persists into the existing channel discovery archive.
- Favorite-creator boost in Watch refresh ranking (favorites are processed first and weighted higher in the candidate scoring).
- "New uploads since last visit" indicator on the creator card.
- Recency-weighted topic mix (per-year breakdown of niche fingerprint).
- Side-by-side compare two creators in a split pane.
- Per-creator notes field (already in the table from Phase 1).
- Surface "this channel was previously known as X" if rename detected.
- "View excluded creators" link from any creator page.
- Channel page cache invalidation policy (refresh stale data).
- Keyboard shortcuts polish: `⌘1`–`⌘0` to jump to sections.
- Inspector polish for video selection from the page.

### In scope — per-creator niche analysis (new in this revision)

These features extend the creator detail page with research-grade analysis. All build on the Phase 1 `OutlierAnalytics` module and the Phase 2 LLM theme infrastructure. None require new YouTube API spend.

- **"Their hits" section.** A dedicated section above All Videos showing this creator's top outliers — videos with the highest `outlierScore`. Distinct from Essentials (which is recency-weighted) by ranking purely on punch-above-weight, no recency tilt. Useful when researching "what's the best work from this creator regardless of when it dropped."

- **Title pattern extraction.** Run the creator's outlier titles through Claude Haiku once and extract 3-5 recurring templates ("I tried X for a week", "Why I switched from X to Y", "Best X for beginners"). Cached in a new `creator_title_patterns` table. Surfaces as a small "Patterns in their hits" section. Costs ~$0.001 per creator, on demand only.

- **Series detection + standout episodes.** Phase 2's regex pre-pass detects series (`Episode N`, `Day N`, `Part N`). Phase 3 surfaces the **standout episode of each series** — the outlier within the series, computed via `OutlierAnalytics.topOutliers(...)` over the series subset. Answers "what's the must-watch episode of this series?"

- **Their share of voice per topic.** For each topic the creator publishes in, show three numbers: their share of saved videos, their share of total views, their share of recency (last 90 days). Renders as a small per-topic strip inside the existing niche fingerprint section. Reveals which topics this creator dominates vs dabbles in.

- **Outlier baseline transparency.** Tooltip on the `↑` outlier badges in the All Videos table showing "view count is N× this creator's median (12K vs 3.2K median)." Educational and debug-friendly.

### Out of scope for Phase 3

- Cross-creator network graph visualization (deferred to Phase 4).
- Per-topic detail page (Phase 4).
- Library-wide insights mode (Phase 4).
- Public competitor leaderboards.
- Anything requiring YouTube view-graph data.

### Data model changes (Phase 3)

```sql
CREATE TABLE creator_title_patterns (
    channel_id TEXT NOT NULL,
    pattern_template TEXT NOT NULL,    -- e.g. "I tried {X} for a week"
    pattern_order INTEGER NOT NULL,
    example_video_ids TEXT NOT NULL,   -- JSON array of video IDs that match
    extracted_at TEXT NOT NULL,
    PRIMARY KEY (channel_id, pattern_template)
);
```

## Phase 4 — Library research tools (Topic & Library insights)

**Scope:** New product surface area for library-wide niche analysis. This is the largest phase by scope — it introduces a per-topic detail page and a new Library Insights top-level mode. Informed entirely by the research-tools survey in Appendix D.

The framing reorientation: a creator asks "where can I rank?", a curator asks "what's worth watching, who's doing the best work, where should I look next?" Phase 4 builds the curator-focused versions of patterns the creator-tools popularized.

### Why this is its own phase

Phase 1-3 all extend the creator detail page itself. Phase 4 introduces two entirely new views (Topic Detail Page, Library Insights mode) and the navigation surface to reach them. It also requires its own analysis modules. Treating it as Phase 4 keeps Phase 3 focused on per-creator polish and lets us validate the outlier-scoring foundation before scaling up.

### In scope — per-topic analysis (new TopicDetailView)

A new full-screen route reachable from any topic in the sidebar by `⌥`-clicking or right-click → "Open Topic Page". Mirrors the creator detail page structurally — same breadcrumb-style navigation, same toolbar pattern, same Apple browse-detail shape — but for a topic instead of a creator.

Sections:

- **Topic dashboard** (header strip): total saved videos, total creators, total views, most active creator, sparsest period, recent trend chart.
- **Creator dominance leaderboard.** Rank all creators by share of voice in this topic. Three sortable orderings: by save count, by view count, by recency. Click a creator → push the creator detail page.
- **Topic outlier feed.** Videos in this topic where `views >= topicMedian * 3`. The "must-watch in this niche" view, computed across all creators. Same `OutlierAnalytics` module, applied to the per-topic distribution.
- **Topic title patterns.** LLM-extracted recurring patterns across all top performers in the topic, not just one creator. Surfaces niche-wide hooks. Cached in a `topic_title_patterns` table.
- **Topic evolution over time.** A 12-quarter line chart of new saves per quarter. See how this topic has grown or fallen off in your library.
- **Subtopic suggestions.** If LLM enrichment is on, suggest sub-topics that emerge from the title patterns.

### In scope — library-wide analysis (new LibraryInsightsView mode)

A new top-level mode in the sidebar alongside Saved and Watch, called "Insights" or "Research" (TBD). Contains four panels:

- **Topic saturation map.** A `Charts` scatter plot. X-axis = number of creators in topic, Y-axis = total saves OR median view count. Each topic is a labeled dot. Sparse + low-view = neglected niche; dense + high-view = saturated. Helps the user understand library composition at a glance.
- **Cross-creator topic overlap matrix.** For the top N creators (default 20, configurable): an N×N grid showing how many topics each pair shares. Reveals redundancy ("three creators all in the same 5 topics") and fragility ("creators with no overlap with anyone — single-source topics").
- **"Trending in your library this month" feed.** A global feed of outliers from the past 30 days across the whole library. Personal version of vidIQ's outlier feed scoped to your tracked creators.
- **Library health dashboard.** A small set of warning cards:
  - **Dormant creators**: tracked creators who haven't posted in 90+ days
  - **Single-source topics**: topics with only one active creator (fragile)
  - **Stale topics**: topics with no new saved videos in 90+ days
  - **Coverage gaps**: subtopic suggestions that have no saved videos
  - **Recently breaking**: topics that just had an outlier event

### Data model changes (Phase 4)

```sql
CREATE TABLE topic_title_patterns (
    topic_id INTEGER NOT NULL,
    pattern_template TEXT NOT NULL,
    pattern_order INTEGER NOT NULL,
    example_video_ids TEXT NOT NULL,
    extracted_at TEXT NOT NULL,
    PRIMARY KEY (topic_id, pattern_template)
);

CREATE TABLE outlier_baseline_cache (
    scope TEXT NOT NULL,                -- "channel:UC..." or "topic:42"
    median_views INTEGER NOT NULL,
    sample_size INTEGER NOT NULL,
    computed_at TEXT NOT NULL,
    PRIMARY KEY (scope)
);
```

The `outlier_baseline_cache` is a small memoization layer so we don't recompute medians on every page open. Invalidated when the underlying dataset changes (new saves, new archive videos).

### New analysis modules (Phase 4)

- **`Sources/VideoOrganizer/TopicAnalytics.swift`** — per-topic statistics (medians, dominance ranking, evolution chart data, saturation coordinates).
- **`Sources/VideoOrganizer/LibraryOverlapAnalytics.swift`** — cross-creator topic overlap matrix, dormancy detection, single-source topic detection.
- **`Sources/VideoOrganizer/LibraryInsightsViewModel.swift`** — aggregates the four library panels into one model.

### New views (Phase 4)

- **`Sources/VideoOrganizer/TopicDetailView.swift`** — the per-topic detail page.
- **`Sources/VideoOrganizer/LibraryInsightsView.swift`** — the library insights mode.
- **`Sources/VideoOrganizer/TopicSaturationChart.swift`** — the scatter plot.
- **`Sources/VideoOrganizer/CreatorOverlapMatrix.swift`** — the N×N grid.
- **`Sources/VideoOrganizer/LibraryHealthCards.swift`** — the warning card stack.

### Out of scope for Phase 4

- Cross-library comparisons (you only have your own library).
- Real social/audience overlap (we don't have view-graph data, only library overlap).
- AI title or thumbnail generation (we're researchers, not creators).
- Keyword search volume / competition scoring (not relevant to a curator).
- Subscriber growth projections.
- Brand safety scoring.
- Multi-platform aggregation.
- Public sharing or social features.

### Cost / data implications

Almost everything in Phase 4 is **free**: pure statistics over the existing library. The only LLM cost is title pattern extraction at the topic level (`topic_title_patterns`), bounded by the number of topics × the same per-creator cost discipline (~$0.001 per topic, cached). For 25 topics in a library, that's roughly 2-3 cents one-time.

No new YouTube API spend at all. The deeper upload backfill from Phase 3 helps because more data → better outlier detection, but Phase 4 ships standalone with whatever data the library already has.

## Phasing summary

| Phase | Scope | Effort | New API spend | New persistence | Notable foundation |
|---|---|---|---|---|---|
| 1 | Creator detail page MVP + outlier scoring foundation | ~1 week | $0 | `favorite_channels` | `OutlierAnalytics` module — reused by every later phase |
| 1 polish | Recent uploads grid (replaces single What's new), surfaced during manual testing | ~half day | $0 | none | Reuses `CollectionGridView` card visual treatment |
| 2 | LLM themes, about paragraph, **per-creator search**, **LLM tag capsules**, **competitor leaderboard**, **`from:` main-search syntax** | ~1.5 weeks | ~$0.005 / creator, cached | `creator_themes`, `creator_about` | LLM caching + cost discipline pattern; new navigation surfaces on creator page |
| 3 | Deep history, polish, per-creator niche analysis (their hits, title patterns, series standouts, share of voice) | ~1 week | ~$0.001 / creator for title patterns | `creator_title_patterns` | Per-creator analysis built on `OutlierAnalytics` + Phase 2 LLM infra |
| 4 | Per-topic detail page + library insights mode (topic dominance, saturation map, overlap matrix, library health) | ~2-3 weeks | ~$0.001 / topic for title patterns | `topic_title_patterns`, `outlier_baseline_cache` | New `TopicAnalytics` and `LibraryOverlapAnalytics` modules; new top-level mode |

Phases are independent — Phase 1 ships standalone as a meaningful upgrade. Phase 4 is the largest and introduces new product surface area; the others are extensions of the creator detail page itself.

**Outlier scoring is the cross-cutting primitive.** Phase 1 introduces it as a small reusable module specifically for the Essentials section, but every subsequent phase (and even some surfaces outside the creator page, like the topic grid badge) consumes the same module. This is the highest-leverage architectural decision in the plan.

## Open questions

1. **Where does the page live in navigation? RESOLVED.** Push onto a new `NavigationStack` inside the detail column **and auto-collapse the sidebar to `.detailOnly`** on entry, restoring on exit. Pattern matches Photos.app's person detail and Music.app's album navigation: the central area takes over, the toolbar's standard sidebar toggle (`⌘0`) lets the user bring the sidebar back if they want. Alternatives rejected: `.fullScreenCover` (too modal, removes toolbar chrome the user wants), separate window per creator (disconnected from sidebar context). We may add `⌘⌥`-click to open in new window in Phase 3 as a power-user affordance.

2. **What does "click a creator name" actually do today?** Need to audit `CollectionGridView` and `VideoInspector` to find every place a creator name is rendered and confirm which click target should push the new page vs. preserve existing behavior. The `CreatorCirclesBar` click already filters the grid; the new "open creator page" should be either a right-click action or `⌥`-click.

3. **What happens to `inspectedCreatorName` state?** It's used by the current inspector creator panel. Phase 1 should leave that state machine intact — the new page is additive, not a replacement, until we decide whether to retire the inspector creator panel entirely. Recommend retiring it once the page exists.

4. **How do we render section headers?** `.headerProminence(.increased)` produces the right look for grouped lists but does not apply uniformly to free-floating `Text` headers in a `LazyVStack`. May need a small `SectionHeader` view that uses `.font(.title2.weight(.semibold))` and `.foregroundStyle(.primary)` consistently.

5. **Does the `NavigationStack` interfere with existing grid scroll restoration?** This is the biggest Phase 1 risk. The `CollectionGridAppKit` host has been sensitive to layout invalidation in the past. Test thoroughly, and have a fallback plan to present `CreatorDetailView` as a `.fullScreenCover` or push-replacement if the stack causes regressions.

6. **Where does the subtitle come from in Phase 1?** Either:
   - First sentence of `channel.description` (if populated by API)
   - First N characters of the channel description
   - Fallback: `<creator_tier> · <topic_count> topics`
   Phase 2 can replace it with an LLM-generated subtitle if the description is missing or weak.

7. **What happens when a creator has < 5 videos?** Many creator pages won't have enough data for charts and essentials. The page should gracefully degrade — hide Essentials shelf if < 6 videos, hide cadence chart if < 12 months of data, show a "More data needed" placeholder where appropriate.

## Risks

| Risk | Mitigation |
|---|---|
| `NavigationStack` integration breaks `CollectionGridAppKit` scroll/selection state | Test under realistic data, have a `.fullScreenCover` fallback |
| `CreatorAnalytics` migration to `channelId` orphans existing inspector calls | Keep both signatures during migration, deprecate over one release |
| LLM theme classification quality is poor | Phase 2 only; ship with a clear off-by-default toggle and a "Refresh themes" button |
| Per-creator scrape (Phase 3) hits YouTube rate limits | Throttle, only on user click, no auto-fire |
| Cache staleness between favorite/exclude actions and the page | Re-fetch `CreatorPageViewModel` on `.task(id: channelId)` and on action callbacks |
| Inspector and detail page both showing creator info confusingly | Phase 1 retires the in-inspector creator panel as soon as the page ships |

## Testing strategy

### Unit tests
- `CreatorPageBuilder.makePage` for a channel with: only saved videos, only archive videos, both, none.
- `OutlierAnalytics`: median computation, outlier score, top-N selection, edge cases (N < 6 fallback to mean, all-null views, single dominant outlier capping, ties).
- `OutlierAnalytics.isOutlier` against known fixtures so the badge predicate is stable.
- Essentials scoring algorithm with synthetic input across creator sizes (small, mid, mega).
- `topicShare` calculation including subtopic rollups.
- `favorite_channels` CRUD.
- Migration test: `creatorDetail(channelName:)` and `creatorDetail(channelId:)` return equivalent results for the same creator.

### Integration tests
- Navigation push from grid → creator page → back, verifying scroll position and selection are preserved.
- Inspector behavior when a row is selected on the creator page.
- Toolbar actions (Pin, Exclude, YouTube) update state correctly.
- Page handles the < 5 videos and < 12 months of data edge cases gracefully.

### Manual smoke checklist
- Open page for a high-volume creator (~100+ saved videos).
- Open page for a low-volume creator (~3 saved videos).
- Open page for a creator with archive but no saved videos.
- Confirm the page loads in < 200ms (it should — all data is in memory).
- Confirm Essentials shelf scrolls horizontally without snapping issues.
- Confirm the All Videos table sorts by every column.
- Confirm Pin / Exclude / YouTube toolbar buttons work.
- Confirm `⌘[` returns to the topic grid.
- Confirm the inspector pane shows video details when a row is selected.

## File-by-file deliverables (Phase 1)

### New files
- `Sources/VideoOrganizer/CreatorDetailView.swift` — the page itself.
- `Sources/VideoOrganizer/CreatorPageViewModel.swift` — the aggregate model.
- `Sources/VideoOrganizer/OrganizerStore+CreatorPage.swift` — the builder.
- `Sources/VideoOrganizer/OrganizerStore+FavoriteCreators.swift` — favorite_channels CRUD and actions.
- `Sources/VideoOrganizer/OutlierAnalytics.swift` — reusable outlier-scoring primitives (median, score, top, badge predicate).
- `Tests/VideoOrganizerTests/CreatorPageBuilderTests.swift`
- `Tests/VideoOrganizerTests/FavoriteCreatorsTests.swift`
- `Tests/VideoOrganizerTests/OutlierAnalyticsTests.swift` — tests for median computation, scoring, edge cases (N < 6, all-null views, single dominant outlier).

### Modified files
- `Sources/TaggingKit/TopicStore.swift` — add `favorite_channels` table + CRUD.
- `Sources/VideoOrganizer/OrganizerStore.swift` — add `favoriteChannels` cache + refresh, add channel-id-keyed `creatorDetail(channelId:)`.
- `Sources/VideoOrganizer/OrganizerStore+CreatorAnalytics.swift` — migrate primary entry point to `channelId`-keyed, keep `channelName` variant for back-compat.
- `Sources/VideoOrganizer/OrganizerView.swift` — wrap detail column in `NavigationStack`, add navigation path state.
- `Sources/VideoOrganizer/CollectionGridView.swift` (or `CollectionGridAppKit.swift`) — wire creator name clicks to push the new page; optionally add outlier badge to existing video cards (single-line predicate check).
- `Sources/VideoOrganizer/VideoInspector.swift` — wire creator name click to push the new page.
- `Sources/VideoOrganizer/CreatorCirclesBar.swift` — add right-click "Open Creator Page" menu item.

## Done criteria for Phase 1

- Clicking a creator name from grid, inspector, or creator-circles right-click menu pushes the creator detail page onto the navigation stack.
- The page renders all 7 Phase 1 sections with real data for any creator that has saved videos.
- Toolbar actions (Pin, Exclude, Open in YouTube) work and persist.
- Selecting a video on the page populates the inspector.
- Back navigation returns to the previous view with grid scroll/selection preserved.
- 147+ existing tests still pass; new tests cover the builder and the favorite_channels persistence.
- `swift build` clean. Pre-commit hook tests pass.
- The page handles the empty-data edge cases without crashing.
- The legacy in-inspector creator panel is removed in the same commit, or scheduled for removal in the next.

---

## Appendix A — research summary (compressed)

### Apple Music artist page sections (canonical)
1. Motion Art
2. Latest Release
3. Essential Albums
4. Albums
5. Top Videos
6. Artist Playlists
7. Singles & EPs
8. Appears On
9. About Me (bio + Similar Artists)

Source: [Apple Music for Artists — Artist pages](https://itunespartner.apple.com/music/support/5229-artist-pages)

### App Store product page sections (canonical)
1. Identity card (Icon · Name · Subtitle)
2. App Previews
3. Screenshots
4. Promotional Text → Description
5. In-App Purchases
6. What's New
7. Ratings and Reviews
8. Information

Source: [Creating Your Product Page — App Store, Apple Developer](https://developer.apple.com/app-store/product-page/)

### Combined "native macOS browse-detail page" shape
```
HEADER       Identity card (icon, name, subtitle, action buttons in toolbar)
HIGHLIGHT    Latest / What's New (one prominent recent item)
ESSENTIALS   Curated short list
CATALOG      Full sortable list
RELATED      Where else this entity appears (playlists, categories)
CONTEXT      Description / About / Bio
ANALYTICS    Small graphical card (ratings histogram / niches)
SIMILAR      You Might Also Like (small horizontal shelf)
INFO         Compact metadata at the very bottom
```

This plan instantiates this exact shape for the YouTube creator case.

## Appendix B — what was deliberately rejected from earlier spec drafts

| Idea | Why rejected |
|---|---|
| Big "hero" thumbnail at the top | Web pattern, not native macOS. Music.app uses a tight identity card. |
| Card grids for "most popular videos" | macOS uses numbered lists (`Table`) for ranked items. |
| Horizontal scroll for "in your playlists" | Horizontal scroll is reserved for visual content (Essentials, similar creators). Use vertical lists/tables for textual content. |
| Tabs at the top of the page (Spotify/YouTube native style) | Music.app and App Store use scrolling sections, not tabs, for this. Tabs are a heavier navigation pattern. |
| "Top competitors in similar niches" framing | Misleading — we have no view-graph data. Reframed to "Creators you might like" and acknowledged it's overlap-based. |
| "Dominance vs other creators" | Same issue — implies global YouTube knowledge we don't have. Reframed as "share of your topic library" via the niche fingerprint. |
| Big publishing-cadence chart as its own section | Folded into the compact niches & cadence GroupBox. |
| Tags/keywords as a separate axis from topics | Folded into Phase 2 themes. Doesn't justify a separate section. |
| Floating action buttons in the page header | macOS puts action buttons in the window toolbar. |
| Page-level breadcrumbs as a UI element | Native back button in the toolbar covers this. |

## Appendix C — non-goals for the entire creator detail effort

These are explicitly out of scope across all phases:

- Real YouTube analytics integration (impressions, watch time, demographics). Requires OAuth scopes the app doesn't ask for and is creator-only data anyway.
- A creator timeline / activity feed of new uploads with notifications. (Phase 3 has a "new uploads since last visit" indicator on the page itself, but no system-level notifications.)
- Multi-account / multi-library support.
- Public sharing of creator notes or favorites.
- Creator comparison reports / exports.
- Any AI-generated review or rating of a creator's quality.
- Real audience-graph data (who watches whom). Phase 4 substitutes *library overlap* for *audience overlap* — different signal, computed from your own library only.
- Keyword search volume / SEO competition scoring (creator-tools have it, curators don't need it).
- AI title or thumbnail generation (we're consuming, not creating).

## Appendix D — YouTube research-tools survey

This appendix summarizes the research that informed the outlier-scoring foundation in Phase 1 and the per-creator and library-wide niche analysis features in Phases 3 and 4. The goal of the survey was to map what mature YouTube research/analytics tools actually do, then identify which patterns translate to a *curator* use case (vs the *creator* use case those tools were built for).

### Tool category 1: Creator growth tools

Built for people growing a YouTube channel. Surveyed: vidIQ, TubeBuddy, 1of10, Morningfame.

Common mechanics across this category:

- **Outlier detection.** The most-cited feature in the entire category. An outlier is a video performing significantly above its own channel's median view count. 1of10 advertises "10x to 100x" outliers as a core differentiator. vidIQ's Outliers feature added Shorts coverage in their Summer 2025 drop. The framing: a 1M-view video on a 5M-average channel is normal; a 1M-view video on a 100k-average channel is signal.
- **Keyword + competition scoring.** TubeBuddy's Keyword Explorer combines monthly search volume with a competition difficulty score. Morningfame uses A-F letter grades against the user's channel authority. **Not relevant to a curator** — we're not optimizing for SEO.
- **Title pattern extraction.** Reverse-engineer outliers to find recurring templates. 1of10 markets "thousands of viral title templates extracted from 4M+ outliers."
- **Channel tracking + change detection.** Notify when tracked channels post outliers, detect breakout signals (3x+ median views in 48h), niche trend signals (multiple competitors covering same cluster), strategy shifts (upload frequency changes).

### Tool category 2: Enterprise content intelligence

Built for brands, agencies, and media companies at enterprise pricing. Surveyed: Tubular Labs.

Relevant mechanics:

- **Audience overlap ("Audiences Also Watch").** Real audience-graph data showing what other content this creator's audience consumes. Used for multi-creator campaign planning. **We don't have audience data**, but we have a *library overlap* equivalent.
- **ContentGraph automatic topic classification.** Tubular runs every video through a proprietary classifier into millions of categories. We do the smaller-scale equivalent via `TopicSuggester`.
- **Topic / category trending at scale.**

### Three operations across all the tools

Distilling everything down, there are three distinct *analytical operations* in this whole category:

| Operation | What it computes | Translates to our case? |
|---|---|---|
| Outlier detection | Identify videos performing far above their own baseline | **Yes — directly applicable.** Free with existing data. |
| Pattern extraction | Find recurring structures in titles, thumbnails, formats | **Yes for titles** via LLM or regex. Thumbnails out of scope. |
| Network/overlap analysis | Map relationships between creators | **Yes via library proxy.** Topic overlap within our library, not audience overlap. |
| Keyword research | Search volume + competition for SEO | No — curators don't need it. |
| Trend forecasting | Project future growth | No — vanity metric. |
| Brand safety | Flag risky content | No — out of scope. |
| AI generation | Make titles/thumbnails | No — we're not creating. |

### The curator vs creator framing reorientation

A creator asks "where can I rank?" A curator asks "what's worth watching, who's doing the best work, where should I look next?" The same tools answer different questions:

| Creator question | Curator question (our framing) |
|---|---|
| Which keywords have low competition? | Which topics in my library are sparsely covered? |
| Which of my videos overperformed? | Which video in this creator's catalog is their must-watch? |
| Who are my top competitors? | Which creators in my library cover the same ground (am I being redundant)? |
| What titles are trending? | What title patterns recur in the videos I actually save? |
| When are my competitors posting? | Which of my creators have gone dormant? |
| Where can I get views? | What's growing in my library this quarter? |
| What's the audience overlap? | If I dropped a creator, what topic coverage would I lose? |

This reframing drives every feature in Phases 3 and 4. The data is the same; the *questions* are inverted.

### The single most important takeaway

**Outlier scoring alone justifies most of the analysis work in this plan.** It's the one mechanic every leader in the creator-tools category agrees on, costs nothing to compute, and immediately improves the curator's ability to find quality videos. Phase 1 introduces it as a small reusable module specifically for the Essentials section, but the same module gets reused across the creator detail page (Essentials, badge), the topic grid (Phase 1, optional), the topic detail page (Phase 4 outlier feed), and library insights (Phase 4 trending feed).

The framing reorientation from "most viewed" to "punched above the creator's baseline" is the same mental shift Spotify made when introducing "Songs you might like" alongside "Top tracks." Top-tracks rewards what's already big; outlier scoring rewards what's unexpectedly good. For a curator's tool, the second is much more useful.

### Sources

- [vidIQ Outliers — vidIQ Help Center](https://support.vidiq.com/en/articles/9660010-outliers)
- [Find YouTube Outlier Videos — vidIQ](https://vidiq.com/features/outliers/)
- [vidIQ Summer 2025 Drop](https://vidiq.com/blog/post/summer-2025-drop/)
- [TubeBuddy Keyword Explorer](https://www.tubebuddy.com/tools/keyword-explorer/)
- [How is the Keyword Score Calculated — TubeBuddy](https://support.tubebuddy.com/hc/en-us/articles/9324740260379-How-is-the-Keyword-Score-Calculated-in-Keyword-Explorer)
- [1of10 — AI-Powered YouTube Growth & Viral Idea Finder](https://1of10.com/)
- [1of10 — All Features](https://1of10.com/features)
- [Morningfame Review 2025 — outlierkit](https://outlierkit.com/blog/morningfame-review)
- [Best Niche Finder Tools For YouTube 2026 — outlierkit](https://outlierkit.com/blog/best-niche-finder-tools-for-youtube)
- [TubeLab Niche Analyzer](https://tubelab.net/niche-analyzer)
- [YouTube Content Gap Analysis — Subscribr](https://subscribr.ai/p/youtube-content-gap-analysis)
- [Tubular Intelligence — Tubular Labs](https://tubularlabs.com/products/tubular-intelligence/)
- [Tubular Labs Review — Influencer Marketing Hub](https://influencermarketinghub.com/tubular-labs/)

## Appendix E — improvements requested during Phase 1 manual testing

Captured live during the user's first manual exercise of Phase 1 in the running app. Each item is queued into the appropriate phase. None are blocking the Phase 1 ship — Phase 1 is complete and shipped — but they should land before any user-facing announcement of the creator detail page feature.

### 1. Recent uploads grid (replaces single "What's new" row)

**Phase:** 1 polish (~half day)

**Problem:** Phase 1's "What's new" section shows exactly one video — the most recent upload. A creator who drops 3 videos in 2 days has the 2nd and 3rd hidden until the user scrolls to the All Videos table.

**Fix:** Bounded recent-uploads section keyed off a 14-day window, rendered using the **same grid styling as the main `CollectionGridView`** (not a stacked-row treatment). Cap at 5; show single most recent as fallback when the window is empty; "+ N more" link when over cap.

Section header: `What's new` (1 item) or `Recent uploads · last 14 days` (2+).

See the "Phase 1 polish" subsection above for the full spec.

### 2. Per-creator search box

**Phase:** 2 (no new persistence, no LLM)

**Request:** A search field on the creator detail page that filters to titles by **just this creator**, distinct from the main app search which spans the whole library.

**Placement:** Inline above the All Videos table, not in the toolbar:

```
All videos                          [⌕ Search this creator's videos        ]   [Sort ▾]
```

**Behavior:** Case-insensitive title substring match. Combines with tag-capsule filtering as an intersection. Cleared on navigation away from the page. Stored as `@State` on `CreatorDetailView`, no persistence.

### 3. `from:` advanced search syntax (main app search)

**Phase:** 2 (could be split into its own small commit and shipped independently)

**Request:** A new operator on the main app's search input. `from:CreatorName` narrows results to a specific creator across the whole library.

**Examples:**
- `from:Hipyo` → all saved videos by Hipyo Tech (substring match on channel name)
- `keyboard from:Hipyo` → keyboard-related videos by Hipyo Tech only
- `from:"Studio No Ha"` → exact phrase match for creators with spaces in their names

**Implementation note:** Need to audit whether the existing main search has a parsed-query infrastructure that can host new operators, or whether this commit introduces it. If introducing it, design the operator pattern to also accommodate `topic:`, `playlist:`, and future operators in one shared module.

This is technically a main-app feature, not a creator-detail-page feature, but it's queued in Phase 2 because it was requested in the same conversation and shares the "creator-keyed navigation" theme.

### 4. LLM-driven tag capsules (theme navigation)

**Phase:** 2 (extends `CreatorThemeClassifier` infrastructure)

**Request:** Use the existing Phase 2 LLM theme processing of titles to generate clickable **tag capsules with counts** that let users navigate sub-themes within a creator's catalog.

**Visual:** A horizontal row of capsule-style filter chips above the All Videos table:

```
[Build vlogs · 12]  [Switch reviews · 8]  [Tutorials · 5]  [Hot takes · 3]  ...
```

**Behavior:**
- Click a capsule → filter the All Videos table to that theme
- Multi-select via cmd-click → union (broader filter) or intersection (narrower); pick whichever feels right after testing
- "Clear" capsule appears when any filter is active
- Combines with the per-creator search box (intersection)

**Position:** Between the Essentials shelf and the All Videos table. Discoverable but doesn't compete with the curated picks above.

This makes the LLM theme clusters a first-class **navigation** surface, not just a separate "By theme" section. The two can coexist — capsules above the table for filtering, the disclosure-group "By theme" section elsewhere on the page for browsing.

### 5. Competitor leaderboard (replaces "Creators you might like")

**Phase:** 2 (uses `OutlierAnalytics` from Phase 1, no LLM required)

**Request:** A **leaderboard-style** competitor view on the creator page, scoped to creators currently tracked in the user's library. Supersedes the original Phase 2 "Creators you might like" / Spotify "Fans Also Like" section — the user wants ranking, not affinity discovery.

**Visual:**

```
Top creators in this niche                                  [scope: top topic ▾]

  1.  [avatar] Hipyo Tech              247 saved · 1.2M subs · 89 outliers   ▸
  2.  [avatar] TaehaTypes               89 saved · 410K subs · 32 outliers   ▸
  3.  [avatar] Switch & Click           71 saved · 220K subs · 24 outliers   ▸
  ...
```

**Ranking criteria** (tunable, default to "saved videos in shared topics"):
- By saved count: how many videos from each creator are in the topics this creator publishes in
- By outlier count: how many videos in shared topics qualify as outliers (uses Phase 1 `OutlierAnalytics`)
- By total views: sum of parsed view counts in shared topics

**Scope picker** at the top of the section lets the user pick which topic the leaderboard is computed against. Default: this creator's primary topic (the one with the most of their saved videos).

**Click any row** to push that creator's detail page onto the navigation stack — chained creator browsing for free.

Computed entirely from existing library data plus `OutlierAnalytics`. No new API spend. No LLM required (though the topic share data feeding it benefits from LLM-derived themes when available).

This framing fits the user's curator/research mindset better than the original "Creators you might like" pattern. The creator detail page is a research destination, not an affinity-discovery surface — the leaderboard correctly emphasizes "who else is doing the work in this niche" over "who else might you like."
