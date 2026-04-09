# Watch Performance and Responsiveness Plan

## Status
Draft implementation plan.

## Summary
`Watch` currently has the right product direction, but large topics like `Mechanical Keyboards` still create two bad user experiences:

- the app appears frozen when entering `Watch`
- scrolling into a new topic can stall the UI again

The goal of this plan is to make `Watch` feel continuously responsive without a large rewrite.

The core principle is:

- the UI should always render from cached state
- expensive discovery and watch-pool work should happen incrementally in the background
- visible topics should be prioritized over off-screen topics

## Goals
- The app should never beachball when entering `Watch`.
- The machine should remain responsive while `Watch` is refreshing.
- Scrolling should remain smooth, even when new topics enter view.
- The UI should clearly communicate when cached results are being shown versus refreshed results.
- The implementation should stay incremental and avoid a large architecture rewrite.

## Non-Goals
- No full rewrite of the grid architecture.
- No new database tables or schema changes.
- No complex job scheduler.
- No speculative multi-process worker system.
- No attempt to fully solve all discovery quality issues in the same pass.

## Current Problems
### 1. Entering `Watch` still does too much work up front
Even after materializing watch pools, the app still performs enough work during or immediately after mode switch that the first transition can feel frozen.

### 2. New topic boundaries still trigger heavy updates
When the user scrolls into a new topic, the app can still:

- update viewport state
- update sidebar state
- update sticky headers
- update topic progress
- trigger topic-specific refresh behavior

That creates visible hitches.

### 3. UI feedback is too coarse
The global HUD exists, but it does not fully explain whether the app is:

- showing cached content
- refreshing the current topic
- waiting on background topics

So a stall feels like a freeze instead of “work in progress.”

## Design Principles
### 1. Render from cached state only
Scrolling and rendering should read precomputed data structures only.

No scroll-driven path should trigger:

- database reads
- watch-pool recomputation
- creator-face recomputation
- large section rebuilds

### 2. Refresh incrementally
Refreshing `Watch` should be topic-by-topic, not page-wide.

The user should see:

- cached content immediately
- visible topics improve first
- off-screen topics update later

### 3. Prioritize what the user can see
The app should spend its first refresh budget on:

1. the selected topic
2. currently visible topics
3. adjacent nearby topics
4. everything else

### 4. Coalesce UI state changes
Sidebar highlight, sticky header updates, and progress updates should happen only when the effective visible topic/creator actually changes, not every scroll tick.

## Proposed Changes

## Phase A: UI feedback and scheduling
### A1. Show cached `Watch` immediately
When the user switches to `Watch`:

- switch modes immediately
- render the current cached watch pools immediately
- start background refresh asynchronously

This is already partially true, but it should become the explicit contract for `Watch`.

### A2. Refine the HUD state model
Replace the current generic Watch HUD with a more explicit, minimal state:

- title:
  - `Refreshing Watch`
- progress:
  - one progress bar
- short status:
  - `Refreshing visible topics first`
  - or `Refreshing Mechanical Keyboards`

Keep it to one primary line plus progress. No long descriptions.

### A3. Add lightweight per-topic refresh state
In the topic header, show only one subtle inline state when relevant:

- `Refreshing…`
- or a tiny spinner

Only for topics currently being refreshed.

Do not replace cached cards with loading placeholders unless the topic truly has no cached watch content.

## Phase B: Prioritized incremental refresh
### B1. Refresh selected topic first
On `Watch` entry:

- refresh the selected topic first
- publish updated watch pool for that topic
- then continue to other topics

This gives the user a fast first meaningful result.

### B2. Refresh visible topics next
Track which topic IDs are currently visible in the grid.

Use that set to prioritize the next topics to refresh after the selected topic.

### B3. Defer background topics
Everything not currently visible should refresh later with lower priority.

This avoids front-loading work that the user cannot see yet.

### B4. Yield between topic refreshes
After each topic refresh:

- update the topic’s cached watch pool
- publish the new state
- yield back to the run loop before processing the next topic

This is critical for keeping the app responsive.

## Phase C: Eliminate scroll-triggered heavy work
### C1. Scroll should read cached section state only
When scrolling, the app should only:

- compute which topic is active
- compute which creator header is docked
- update the thin progress bar

All of those should use already-built section metadata.

### C2. Coalesce sidebar updates
Only update sidebar viewport selection when:

- the active topic actually changes
- the active creator actually changes

Do not animate or scroll the sidebar continuously during fine-grained movement inside the same section.

### C3. Avoid header reconfiguration during scroll
Sticky headers and creator face piles should be configured when:

- a topic section is first built
- or the underlying topic watch pool changes

They should not be rebuilt on every scroll event.

## Phase D: Narrow recomputation scope
### D1. Rebuild one topic pool at a time
When `ensureCandidates(for:)` completes for topic `T`:

- update `storedCandidateVideosByTopic[T]`
- rebuild the watch pool for `T`
- update global derived state only as needed

Do not rebuild every topic pool from scratch unless a global input really changed.

### D2. Rebuild `Show All` in batches
The global `Show All` pool can be recomputed:

- after the selected topic completes
- then after every few topic updates
- or after a short debounce window

It does not need to rerank globally after every single small topic change.

### D3. Cache creator-face models
For each topic, cache the creator-face row model used by `Watch`.

Inputs:

- current watch pool for that topic
- current creator filter

This avoids repeated face-pile recomputation while rendering and scrolling.

## Implementation Steps
### Step 1. Add a visible-topic priority queue
Track:

- selected topic
- visible topic IDs
- refresh completion state

Refresh order:

1. selected topic
2. visible topics
3. remaining topics

### Step 2. Move per-topic watch-pool rebuild to incremental updates
Instead of treating `rebuildWatchPools()` as a whole-page operation:

- add a per-topic rebuild path
- update only the affected topic’s watch pool
- maintain `rankedWatchPool` separately with batched recomputation

### Step 3. Debounce `Show All` rerank
Add a short debounce for global reranking so multiple topic updates coalesce into one `Show All` rebuild.

### Step 4. Add clearer refresh state
Expose:

- which topic is currently refreshing
- which topics are still using cached data

Feed this into:

- global HUD
- topic header inline state

### Step 5. Tighten scroll feedback updates
Ensure scroll feedback updates only when section identity changes, not just visible bounds.

## Likely Files To Change
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/OrganizerStore.swift`
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/OrganizerStore+CandidateDiscovery.swift`
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/CollectionGridView.swift`
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/OrganizerView.swift`
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/TopicSidebar.swift`

## Test Plan
### Logic tests
Add tests for:

- selected topic refresh ordering
- visible topic prioritization
- per-topic watch pool rebuild without global full recompute
- batched `Show All` rerank behavior

### Manual validation
Test these cases with a large topic like `Mechanical Keyboards`:

1. click `Watch`
- app switches immediately
- cached content appears immediately
- no beachball

2. wait during refresh
- HUD remains visible
- selected topic updates first
- off-screen topics update later

3. scroll into a new topic
- no freeze
- sidebar highlight updates only when the topic actually changes
- creator face pile remains stable

4. switch to `Show All`
- no global stall
- list remains usable while background refresh continues

## Success Criteria
- Clicking `Watch` never makes the app or machine feel frozen.
- The first visible topic becomes usable quickly.
- Scrolling through topics remains smooth while refresh is active.
- The user can always tell whether they are looking at cached or refreshing content.
- The implementation remains incremental and local to the existing store/grid architecture.
