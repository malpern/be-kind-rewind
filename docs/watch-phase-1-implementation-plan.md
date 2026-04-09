# Watch Phase 1 Implementation Plan

## Goal
Make `Watch` internally consistent and predictable before expanding discovery breadth.

Phase 1 does not add search-based discovery yet.

It makes the existing watch experience coherent by unifying:
- freshness rules
- eligibility
- counts
- creator faces
- filtering
- `By Topic` vs `Show All`

## Scope
### In scope
- One recent watch pool per topic.
- Consistent watch counts and creator faces.
- Real watch-mode creator filtering.
- `Show All` built from the same watch pools.
- Tighter admission for adjacent creators.

### Out of scope
- Search/query discovery lane.
- User-facing query management UI.
- Older-gems mode.
- Full candidate-to-subtopic classifier redesign.

## Product Rules To Implement
### 1. Define one recent pool per topic
Add one central helper in the watch data layer that returns:
- recent, eligible watch videos for a topic

This should become the source of truth for:
- topic cards
- topic counts
- creator faces
- creator counts
- watch filtering

Suggested default:
- last 30 days

### 2. Make `By Topic` use only that pool
Current issue:
- `candidateVideosForTopic(...)` returns the stored topic candidates, which can include older backlog items

Phase 1 change:
- keep stored candidates in SQLite
- but derive the visible watch set from the recent eligible subset of those candidates

### 3. Make `Show All` use the union of those same pools
Current issue:
- `Show All` uses topic candidate flattening with separate dedupe/rerank behavior
- freshness/count semantics are not aligned with `By Topic`

Phase 1 change:
- build `Show All` from the union of each topic’s recent watch pool
- dedupe by `videoId`
- rerank globally

### 4. Make watch creator counts use the visible pool
Current issue:
- watch creator counts can refer to older candidate backlog or synthetic topic handling

Phase 1 change:
- creator counts in `Watch` always count videos in the recent visible watch pool

### 5. Make watch creator filtering real
Current issue:
- `selectedChannelId` filtering is currently only applied to `.saved` sections in the grid builder

Phase 1 change:
- apply creator filtering to watch sections too
- clicking a creator face in `Watch` should:
  - stay in `Watch`
  - filter the current watch pool
  - toggle off when clicked again

### 6. Tighten adjacent creator admission
Current issue:
- weak adjacency can let marginal creators appear in a topic

Phase 1 change:
- raise the threshold for non-native creators to appear in a topic’s watch pool
- likely require:
  - stronger playlist overlap
  - more than one supporting signal
  - or a minimum score threshold above native-creator candidates

This is still using existing discovery inputs, just with stricter admission.

## Data / Logic Changes
### OrganizerStore
Add explicit watch-pool helpers:
- `watchPoolForTopic(_:)`
- `watchPoolForAllTopics()`
- creator counts and latest dates computed from those pools

The pool helper should:
- start from stored candidates
- exclude placeholders
- apply terminal suppression
- apply recent-window filter
- apply any creator filter if active

### GridSectionBuilder
Change watch section construction so:
- topic watch sections use `watchPoolForTopic(_:)`
- `Show All` uses `watchPoolForAllTopics()`
- creator filtering applies to watch sections, not just saved sections

### TopicSidebar
Use watch-pool counts everywhere in watch mode:
- topic counts
- creator rows
- subtopic counts

If exact subtopic classification is not yet available, keep a clearly documented approximation, but keep topic and creator counts exact.

### CollectionGridView
Header creator circles in watch mode should use:
- creators present in the current watch pool
- counts from that same pool
- freshness ordering from that same pool

`Show All` needs a dedicated global creator-face source instead of relying on fake topic `-1` semantics.

## UI Behavior
### By Topic
- topic header count = watch-pool count
- creator faces = creators in topic watch pool
- clicking creator face = watch-only creator filter

### Show All
- one deduped global watch section
- creator faces = creators in global watch pool
- counts reflect global watch pool
- ordering is freshness-first on faces, score-first on cards

## Ranking Adjustments
Phase 1 keeps the current basic ranking model but applies it only within the recent eligible pool.

Keep:
- creator affinity
- soft seen penalty
- creator diversity penalty

Improve:
- adjacent creator admission threshold

Do not add:
- query-based discovery
- large ranking-system rewrites

## Testing Plan
Add coverage for:
1. recent watch pool excludes older candidates from visible watch sections
2. watch creator filter applies in watch mode
3. `Show All` is built from the union of topic recent pools
4. global watch dedupe still holds
5. creator counts in watch mode reflect the same pool as cards
6. adjacent creators below threshold do not appear in a topic watch pool

## Implementation Order
1. Add explicit watch-pool helpers in `OrganizerStore`.
2. Switch `By Topic` watch rendering to use that pool.
3. Switch `Show All` to use the union of those pools.
4. Apply creator filtering in watch mode.
5. Rewire watch creator-face counts and ordering from the same pool.
6. Tighten adjacent-creator admission.
7. Add tests.
8. Manual validation on:
   - `By Topic`
   - `Show All`
   - creator filter on/off
   - sidebar counts
   - creator-face counts

## Expected Outcome
After Phase 1:
- `Watch` feels recent by default
- counts and faces match what the user is actually seeing
- creator filters behave predictably
- `By Topic` and `Show All` feel like two views of the same system

Then we can add Phase 2:
- search/query discovery for new creators and new videos
