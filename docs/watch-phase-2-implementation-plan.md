# Watch Phase 2 Implementation Plan

## Summary

Phase 1 made `Watch` coherent:

- one recent watch pool per topic
- `By Topic` and `Show All` now derive from the same pool
- counts, creator faces, and creator filtering use the same visible watch universe

Phase 2 should make `Watch` better at discovery.

The goal is to improve novelty without losing trust. Users should see:

- fresh videos from known creators they already care about
- promising new creators that are clearly on-topic or strongly adjacent
- fewer weakly related creators leaking into a topic because of loose library overlap

Phase 2 introduces two changes:

1. tighter creator admission rules
2. a separate search-based discovery lane

## Product Goals

`Watch` should feel:

- fresh
- relevant
- somewhat surprising
- but not noisy or arbitrary

The system should favor:

- recent unseen videos
- known creators with strong topic affinity
- new creators with strong evidence

The system should avoid:

- weakly adjacent creators dominating a topic
- multiple stale videos from the same creator
- confusing users about why a video appeared

## Phase 2 Scope

### 1. Tighten creator admission

Current issue:

- creators can enter a topic’s watch pool via adjacency from playlist overlap / saved-library graph
- this is useful for novelty
- but it is currently too permissive

Phase 2A makes creator admission stricter.

#### Creator classes

For watch discovery, a creator should be classified as one of:

- `known_creator`
- `adjacent_creator`
- `search_creator`

##### Known creator

Definition:

- a creator already strongly associated with the topic through saved videos

Examples of evidence:

- enough saved videos in the topic
- enough saved videos in topic subtopics
- explicit topic-channel assignment through library content

Known creators should remain the highest-confidence lane.

##### Adjacent creator

Definition:

- a creator not yet strongly established in the topic, but inferred from saved-library overlap or graph proximity

Phase 2 rule:

- adjacency alone is no longer sufficient for topic admission

An adjacent creator must also satisfy at least one additional condition:

- multiple recent candidate videos for the topic
- stronger overlap score above a raised threshold
- evidence from topic subtopics
- later: search confirmation

##### Search creator

Definition:

- a creator discovered through search/query-based topic evidence

This is introduced in Phase 2B.

### 2. Add a search-based discovery lane

Current issue:

- `Watch` is still mostly creator/archive-driven
- it is good at “more from people I already know”
- it is weak at “find new creators I haven’t already saved”

Phase 2B adds a separate search lane.

The first version should remain backend-driven and not expose query editing UI.

## Discovery Model

Phase 2 should treat `Watch` as a blend of multiple ranked lanes:

1. `Known Creators`
2. `Adjacent Creators`
3. `Search Discovery`

These lanes are internal implementation/model concepts. The user can still experience one `Watch` page.

### Known Creators lane

Purpose:

- high precision
- low surprise

Source:

- creators already associated with the topic
- existing archive-based creator refresh path

Confidence:

- highest

### Adjacent Creators lane

Purpose:

- controlled exploration near the topic

Source:

- saved-library overlap graph
- playlist co-occurrence
- topic/subtopic creator relationships

Confidence:

- medium

Rule change:

- admission threshold must be stricter than in Phase 1

### Search Discovery lane

Purpose:

- find fresh content from creators not already in the topic graph

Source:

- generated topic queries
- recent YouTube search results

Confidence:

- medium-to-low initially
- improved by filtering and ranking

## Search Discovery V1

### Query generation

Use backend-generated queries only.

Do not build user query management UI in V1.

For each topic, generate 4 queries:

1. exact topic name
2. topic name + `review`
3. topic name + current year
4. one topic-specific modifier

Examples:

For `Mechanical Keyboards`:

- `mechanical keyboard`
- `mechanical keyboard review`
- `mechanical keyboard 2026`
- `mechanical keyboard qmk`

For software/tool topics:

- topic + `tutorial`
- topic + `release`

For newsy topics:

- topic + `news`
- topic + `update`

### Search source

Preferred approach:

- scraper-first or public search path for discovery
- API search optional and constrained because of quota cost

The initial search lane should prioritize recent results only.

### Search result caps

Keep the first version intentionally small:

- 4 queries per topic
- small cap per query
- recent results only

This keeps the lane observable and tunable.

### Search result filtering

Filter out:

- already saved videos
- explicitly watched videos
- dismissed videos
- not interested videos
- duplicates already present in the creator/archive lane

Also apply:

- creator flood control
- minimum quality bar
- freshness gate

## Ranking Model

Phase 2 ranking should still be score-driven, not purely chronological.

But each lane should contribute different signals.

### Shared gating

All watch candidates must satisfy:

- inside the recent watch window
- not explicitly watched
- not dismissed
- not terminally processed

Search-discovered and adjacent creators must also satisfy lane-specific admission rules.

### Shared score signals

- freshness
- unseen-ness
- topic relevance
- creator affinity
- creator diversity penalty
- soft seen/opened penalty

### Lane-specific signals

#### Known creators

- strongest affinity bonus
- lower novelty bonus

#### Adjacent creators

- moderate novelty bonus
- stricter admission threshold

#### Search creators

- higher novelty bonus
- stronger topic-match requirement

### Diversity pass

After initial scoring:

- apply diminishing returns per creator
- apply stronger penalties to repeated older videos from one creator
- allow limited clustering for truly fresh uploads

## Provenance Model

Phase 2 should persist why a watch candidate was admitted.

Each candidate should carry:

- `discovery_lane`
- `discovery_query` (if applicable)
- `admission_reason`

Suggested values:

- `known_creator`
- `adjacent_creator`
- `search_match`

Suggested admission details:

- `topic creator`
- `subtopic creator`
- `high-overlap adjacent creator`
- `matched query: mechanical keyboard review 2026`

## UI Behavior

V1 UI for Phase 2 should remain light.

Do not add query editing.

### What to expose

Show lightweight provenance in the inspector and/or card metadata later:

- `Known Creator`
- `New Find`
- `Matched Search`

Potential detail text:

- `Matched: mechanical keyboard review 2026`

### What not to expose yet

- full query editor
- per-topic manual query management
- advanced discovery controls

Those would create setup burden too early.

## Data Model Changes

### Candidate metadata

Extend stored candidate/source metadata to support:

- discovery lane
- search query provenance
- admission reason

This can be modeled in:

- candidate source table
- candidate metadata table
- or by enriching the existing candidate source records

The exact schema choice should minimize migration complexity.

### Search archive

Initial version can store:

- generated queries
- fetched result metadata
- matched video IDs
- creator IDs/names

This should support:

- debugging quality
- future re-ranking
- future UI provenance

## Implementation Order

### Phase 2A: creator admission tightening

1. Define known vs adjacent creator classification.
2. Raise the adjacency threshold.
3. Require stronger evidence before an adjacent creator enters a topic.
4. Add tests using known false-positive examples.

Expected result:

- fewer off-topic creators in topic watch pools
- higher trust in watch topic membership

### Phase 2B: search discovery lane

1. Generate 4 backend queries per topic.
2. Fetch recent results.
3. Dedupe/filter results.
4. Merge with the existing watch pool.
5. Add provenance metadata.

Expected result:

- more new creators
- fresher discovery beyond the saved graph

### Phase 2C: provenance UI

1. Add lightweight inspector/card source labels.
2. Keep the UI observational, not configurable.

Expected result:

- users can understand why a video appeared
- easier tuning/debugging

## Testing Plan

### Admission tests

Add tests for:

- known creators remain admitted
- weak adjacent creators are rejected
- stronger adjacent creators with topic evidence are admitted

### Search lane tests

Add tests for:

- query generation per topic
- dedupe across multiple queries
- dedupe against known-creator lane
- search-match provenance persistence

### Ranking tests

Add tests for:

- known creator beats weak search noise
- strong fresh search result can beat stale backlog
- creator diversity still holds after merging lanes

## Non-Goals

Phase 2 does not include:

- user-editable search queries
- custom discovery UI controls
- replacing creator/archive discovery
- broad historical search

## Success Criteria

Phase 2 is successful if:

- topic watch pools contain fewer obviously off-topic creators
- `Watch` surfaces more new creators without becoming noisy
- users can understand why a video appeared
- known creators still anchor the experience
- `Show All` feels varied and fresh without losing relevance
