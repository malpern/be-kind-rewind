# Creator Detail Page — Removed Features Archive

This doc captures the three creator-detail-page sections that were removed
during the 2026-04 design simplification pass, in case any of them needs to
come back. The page went from 9 sections to 6: Identity → What's New → Hits
→ All Videos → Playlists → Notes.

The motivating critique was that the page read as a power-user dashboard
rather than a native macOS detail page. Each removed section pulled its
weight on a "this is interesting data" axis but failed on the "this is the
right way to look at this entity" axis.

If you bring any of these back, prefer making it a tab/subview on the
identity card or an explicit affordance the user opts into, rather than
restoring it as a permanent always-visible section.

---

## 1. Niches & Cadence

**What it did:** A two-column GroupBox section with two bar charts side by
side, anchored to `SectionAnchor.niches` (originally ⌘6).

**Left chart — Topic share:** A horizontal bar chart breaking down the
creator's saved videos by which user-defined topic they belong to. Each
topic row showed:
- Topic name (left)
- "their share · library share" two-number readout on the right (the first
  number was this creator's % of their own saved videos in this topic; the
  second was their share-of-voice — i.e. what % of *all* videos in this
  topic across the library belong to this creator)
- A horizontal bar gradient sized to `share.percentage`
- A staleness color rule: ≥25% share-of-voice rendered the second number in
  the accent color so users could spot dominated niches at a glance

A picker above the chart toggled between "All time" and "Last 12 months"
windows. The 12-month window let users see whether a creator's niche mix
had shifted recently (e.g., a mech-keyboard creator pivoting to ergonomic
chairs).

**Right chart — Videos per month:** A `Chart`-based bar chart showing
monthly upload cadence for the last 24 months. Each bar was a month, height
was the count of dated uploads in that month. X-axis stride: 6 months.
Y-axis: 3 ticks, automatic. Below the chart: "N videos · peak M in a
single month" caption.

Both charts had an entrance animation driven by a `chartsAnimationProgress`
@State that ramped 0→1 over 0.7s on every channel switch (the bars grew
into place rather than popping in).

**Skeleton:** When the archive was still loading, the section showed
placeholder skeletons (`nichesSkeletonColumn` + `cadenceSkeletonChart`) at
the same dimensions so the page didn't shift.

**Why removed:** Two charts in a single section is a lot of pixels. The
"share of voice" concept is novel and requires explanation; most users
won't internalize what the second percentage means. The cadence chart is
analytics for someone studying YouTube creators as a phenomenon, not for
someone curating their own library. Neither chart supports a user
*action* — they're just observations.

**Data still computed:** `CreatorPageViewModel.topicShare`,
`topicShareLast12Months`, and `monthlyVideoCounts` are still produced by
`CreatorPageBuilder`. The compute cost is small relative to the rest of
the builder, so keeping them populated lets resurrection be a UI-only
change. If you decide they're permanently dead, strip the producers in
`CreatorPageBuilder.swift` and the corresponding model fields.

**View code lived in:** `CreatorDetailView.swift`, ~lines 2169–2477 prior
to deletion. State: `chartsAnimationProgress`, `topicShareWindow` (with
its `TopicShareWindow` enum). Helpers: `nichesAndCadenceSection`,
`topicShareChart`, `topicShareWindowPicker`, `topicShareRow`,
`shareOfVoiceColor`, `cadenceChart`, `nichesSkeletonColumn`,
`cadenceSkeletonChart`, `activeTopicShare`, `percentageString`.

**To bring it back:** The cleanest reincarnation would be a small
"Cadence" sparkline chart inside the identity card stat tiles row (one
extra tile rendering a 12-bar mini-chart) and dropping topic share
entirely. Two large charts in their own section is too much.

---

## 2. Top creators in this niche (competitor leaderboard)

**What it did:** A ranked list of creators in the same topic as the page
creator, anchored to `SectionAnchor.leaderboard` (originally ⌘7).

The section had two pickers in its header:
- **Topic scope picker** — a Menu listing every topic the page creator
  publishes in. Default: the page creator's primary topic. Lets the user
  ask "who else is in this niche?" against any topic the creator
  participates in.
- **Metric picker** — a Menu (not segmented to avoid the macOS 26
  segmented-Picker prefetch crash) with three options:
  - `.savedCount` — rank by how many videos each creator has saved IN
    THIS TOPIC
  - `.outlierCount` — rank by how many of each creator's videos are
    outliers (≥3× their own median view count, reusing the Phase 1
    OutlierAnalytics primitive)
  - `.totalViews` — rank by sum of view counts in the topic

The page creator's row was highlighted with an accent-tint background and
a "YOU" badge so users could see where they sit in the ranking. Clicking
any other row navigated to that creator's detail page (deep navigation).

Each row showed: rank number, channel avatar (32pt), channel name,
secondary metrics line (the two metrics OTHER than the prominent one,
plus subscriber count), then a big right-aligned figure for the active
metric with its unit caption underneath ("47 saved · in Mech Kbds").

The row used `ChannelIconView` for offline-first icons (looked up from
`store.knownChannelsById[entry.channelId]?.iconData`).

**Why removed:** It's a *comparative* view, not an attribute of the page
creator. Putting it on the creator detail page conflates "tell me about
THIS creator" with "tell me how this creator stacks up against others" —
two different user jobs. Apple Music doesn't put a "top artists in this
genre" leaderboard on the artist page; it has a Browse → Genre surface
for that. Also: the metric picker was added to support three different
ranking orders, which is itself a sign that there's no obvious one
ranking that matters most.

**Data still computed:** `CreatorPageViewModel.leaderboardScopes`,
`leaderboardByTopic`, `leaderboardDefaultTopicId` are still produced by
`CreatorPageBuilder`. `CreatorLeaderboardEntry` and
`CreatorLeaderboardScope` types still exist in `CreatorPageViewModel.swift`.
Resurrection-friendly. Strip the producers later if dead.

**View code lived in:** `CreatorDetailView.swift`, ~lines 2479–2756 prior
to deletion. State: `leaderboardScopeTopicId`, `leaderboardMetric` (with
its `LeaderboardMetric` enum). Helpers: `leaderboardSection`,
`currentLeaderboardScope`, `currentLeaderboardEntries`,
`metricDescription`, `leaderboardScopePicker`, `leaderboardMetricPicker`,
`leaderboardRow`, `metricValueText`, `metricUnitText`,
`leaderboardAvatar`, `leaderboardAvatarFallback`, `leaderboardSubtitle`.

**To bring it back:** The right place is a top-level "Discover → Top
creators in [Topic]" surface, not the creator detail page. If it MUST
return to the creator page, make it a tab/picker on the identity card
("This creator | Other creators in [Topic]") rather than a permanent
section that takes vertical space whether the user wants comparison or
not.

---

## 3. Channel Information section

**What it did:** A bottom-of-page metadata grid + dock area, anchored
just below the Notes section (no `SectionAnchor` of its own — it lived
outside the anchor list, last in the body).

**Metadata grid (`Grid` with two columns):**
- Subscribers
- Total uploads (known) — videos we have in the archive
- Total uploads (reported) — what YouTube says the channel has, when
  it differs from "known"
- In your library — count + coverage % (e.g. "47 (12%)")
- Earliest known upload — founding year if known
- Country
- Last refreshed — formatted timestamp + "N days old" suffix when ≥7
  days stale
- YouTube — link row to `page.youtubeURL`

**"Load full upload history" button** in the section header: triggered
the deeper one-shot scrape (max 200 videos vs the default 16). Showed
inline status: "Loading…" spinner during, "Loaded N more" / "No new
videos" after, persisting for the rest of the session as quiet feedback.
Disabled while in flight. The button rebuilt the page model on
completion via a `.onChange(of: store.lastFullHistoryLoadCount[channelId])`
hook.

**Bottom-docked Exclude / Restore button:** A bordered button at the
very bottom of the section that toggled between "Exclude from Watch"
(destructive role) and "Restore from Watch" (normal role) depending on
`page.isExcluded`. Docked at the bottom intentionally so it couldn't be
mis-clicked from the header — destructive actions in a low-frequency
location.

**Why removed:** A YAML-style metadata grid + a load button + a
destructive bottom dock is three jobs in one section. The metadata is
all derivable from the avatar tooltip + identity card (subscribers
already shows in stats line, country/founding year are tier-line
material). The "Load full history" affordance is a power feature that
~5% of users will ever use. The exclude button shouldn't have its own
dedicated dock — it's a context-menu item.

**Preserved actions:**
- **Subscribers, country, founding year** — moved into the
  identity-card stat tiles + tier line + avatar tooltip in Phase 3
- **Load more uploads** — moved into `identityContextMenuItems` (the
  identity card right-click menu) as a "Load more uploads" item that
  uses `store.loadFullChannelHistory(...)`. Disabled while
  `store.loadingFullHistoryChannels.contains(channelId)` is true.
- **Exclude / Restore from Watch** — already in
  `identityContextMenuItems` with a destructive role; unchanged.
- **Manage Excluded Creators…** — already in `identityContextMenuItems`.

**View code lived in:** `CreatorDetailView.swift`, ~lines 2217–2391
prior to deletion. Helpers: `channelInformationSection`,
`loadFullHistoryButton`, `refreshedRowValue`, `libraryCoverageString`,
`infoRow`, `infoRowLink`, `formatRefreshTime`.

**Data still computed:** `subscriberCount*`, `totalUploadsKnown`,
`totalUploadsReported`, `coveragePercent`, `foundingYear`,
`countryDisplayName`, `lastRefreshedAt` are still on the page model.
Stats tiles in Phase 3 use the first two; the rest are dormant but
cheap.

**To bring it back:** The metadata grid pattern is fine for an Inspector
sidebar (the existing `VideoInspector` does this for individual videos).
If users start asking for "more channel detail," consider an
inspector-sidebar mode for creator pages instead of resurrecting a
bottom section.

---

## What was *not* removed but could be in a future pass

A few sections that survived this pass that are also candidates for
deletion if simplification needs to go further:

- **Hits** (top outliers from the creator) — could be folded into All
  Videos as a "Top Outliers" sort option
- **Playlists** (playlists where this creator's videos appear) — useful
  but lives near the bottom; if Hits goes away, Playlists could move
  up

Don't touch these without explicit feedback from the user — they're
holding their weight today.
