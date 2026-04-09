# Watch Topical Admission Implementation Plan

## Status
Draft implementation plan.

## Summary
`Watch` is currently making the wrong kind of decision too early.

Today, a creator can be considered adjacent to a topic, and then too many of that creator's recent videos can enter the topic even when the individual videos are not actually on-topic.

This shows up as failures like:

- Joe Scotto keyboard videos appearing in `Embedded Systems`
- Linkarzu terminal / Neovim videos appearing in `macOS & Apple`

The right fix is not more reranking or a data-model expansion. The right fix is a simple per-video topical admission gate.

## Goal
Before a video can enter a topic's `Watch` pool, the system should require strong enough evidence that the video itself belongs in that topic.

This should make `Watch` feel:

- more trustworthy
- more predictable
- more obviously on-topic

without reducing the ability to discover new creators.

## Non-Goals
- No schema or migration changes.
- No user-facing topic-keyword editor.
- No embedding system or semantic classifier.
- No ML service dependency.
- No new query-management UI.

## Design Principle
Creators can be discovery sources, but creators should not decide final topic membership by themselves.

Topic admission should happen per video.

## Current Problem
The current `Watch` system already does a good job of:

- discovering recent videos from known creators
- finding adjacent creators
- mixing in a search lane
- assigning each video to a single strongest topic

But it is still too permissive before assignment.

If a video is allowed into the wrong topic candidate set, single-best-topic assignment cannot fix it unless the correct topic also admitted the same video.

## Proposed Fix
Add a topical admission gate that runs before a video is admitted into a topic's watch pool.

The admission gate should be stricter for:

- adjacent-creator videos
- search-discovered videos

It should be looser for:

- known-topic creators

## Evidence Model
For any `(video, topic)` pair, derive a simple evidence score from:

1. creator relationship
2. title lexical match
3. query provenance
4. subtopic lexical match

The goal is not perfect classification. The goal is to reject obviously weak topic matches.

### 1. Creator relationship
Use the existing creator lane classification:

- `known_creator`
- `adjacent_creator`
- `search_creator`

Rules:

- `known_creator` can pass with a lower lexical threshold
- `adjacent_creator` needs stronger lexical evidence
- `search_creator` should need either lexical evidence or an explicit matching query

### 2. Title lexical match
Derive a lightweight topic vocabulary in memory from:

- topic name
- subtopic names
- a small set of hard-coded aliases for ambiguous topics

Examples:

- `Mechanical Keyboards`
  - `keyboard`, `keyboards`, `switch`, `switches`, `keycap`, `keycaps`, `qmk`, `via`, `vial`, `choc`, `mx`, `handwired`
- `macOS & Apple`
  - `macos`, `mac`, `apple`, `macbook`, `finder`, `raycast`, `alfred`, `spotlight`
- `Embedded Systems`
  - `embedded`, `microcontroller`, `firmware`, `esp32`, `stm32`, `arduino`, `pcb`, `rtos`

The title should be normalized once:

- lowercase
- punctuation stripped to token boundaries
- simple token matching, not fuzzy semantics

### 3. Query provenance
If a search-discovered video came from a topic query that directly matches the topic vocabulary, that counts as stronger evidence.

Examples:

- `mechanical keyboard review`
- `macos window management`
- `esp32 project`

This is especially important for search-discovered videos from creators not already in the topic graph.

### 4. Subtopic lexical match
If the title clearly matches a subtopic under the topic, that should count as strong evidence even when the top-level topic name does not appear directly.

Example:

- `QMK tutorial` should strongly support `Mechanical Keyboards`
  even if the title does not say `keyboard`.

## Admission Rules
### Known creator lane
Admit if:

- creator is already established for the topic
- and the video is recent and otherwise watch-eligible
- and it is not obviously contradictory to the topic

Implementation note:

- Start simple: known creators can bypass the strict lexical threshold
- but if a title strongly matches another known topic's vocabulary, that should be allowed to win later in assignment

### Adjacent creator lane
Admit only if:

- creator passes the existing adjacency threshold
- and the title has meaningful lexical overlap with the topic or one of its subtopics

Adjacency alone should no longer be sufficient.

### Search lane
Admit only if:

- the matched query is clearly associated with the topic
- or the title has meaningful lexical overlap with the topic/subtopic vocabulary

Search results without either of those should be dropped.

## Cross-Topic Assignment
Keep the existing one-video-one-topic rule.

But adjust the topic-preference logic so stronger topical evidence wins before generic score.

Preference order:

1. stronger topical admission evidence
2. known-topic creator over adjacent creator
3. search/query evidence over weak adjacency
4. score
5. freshness

This does not replace the admission gate. It complements it.

## Implementation Steps
### Step 1. Add in-memory topic vocabulary helpers
Add a small vocabulary builder in the Watch discovery path.

Inputs:

- topic name
- subtopic names
- optional hard-coded aliases for special topics

Outputs:

- normalized topic keywords
- normalized subtopic keywords

Keep this in code, not in the database.

### Step 2. Add title/topic lexical matching helpers
Add helper functions that:

- normalize titles into tokens
- count topic-vocabulary matches
- count subtopic-vocabulary matches
- return a simple topical evidence summary

Keep this rule-based and inspectable.

### Step 3. Add admission gate for adjacent lane
Before adjacent candidates are admitted for a topic:

- require lexical support from the title or subtopics
- reject videos with no topical lexical support

This should be the first high-impact fix.

### Step 4. Add admission gate for search lane
Before search candidates are admitted:

- require query match support or lexical support
- reject broad recent search results that are only weakly related through creator or popularity

### Step 5. Strengthen assignment preference
Update the single-best-topic assignment comparator to consider:

- topical evidence strength
- creator lane strength

before falling back to score and freshness.

### Step 6. Tune topic aliases
After the first pass, add a small number of topic aliases where needed.

Examples:

- `Mechanical Keyboards`
  - `qmk`, `via`, `vial`, `choc`
- `macOS & Apple`
  - `raycast`, `alfred`, `spotlight`
- `Vim & Terminal`
  - `neovim`, `nvim`, `kitty`, `ghostty`, `tmux`, `wezterm`

This should stay intentionally small.

## Files Likely To Change
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/OrganizerStore+CandidateDiscovery.swift`
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/OrganizerStore.swift`
- `/Users/malpern/local-code/be-kind-rewind/Tests/VideoOrganizerTests/OrganizerStoreTests.swift`

Possibly:

- `/Users/malpern/local-code/be-kind-rewind/Sources/TaggingKit/TopicStore.swift`

Only if the current candidate provenance helpers need small supporting changes. No schema changes are planned.

## Test Plan
Add focused tests for:

1. Adjacent rejection
- keyboard-titled video should not be admitted into `Embedded Systems` via adjacency alone
- terminal / Neovim titled video should not be admitted into `macOS & Apple` via adjacency alone

2. Positive lexical admission
- `QMK` / `handwired` titles should be admitted into `Mechanical Keyboards`
- `esp32` / `firmware` titles should be admitted into `Embedded Systems`

3. Search admission
- search-discovered video with matching query should be admitted
- search-discovered video without query/title support should be rejected

4. Assignment preference
- if a video is admissible to multiple topics, the stronger topical evidence should win

## Rollout Strategy
Implement in this order:

1. adjacent-lane lexical gate
2. search-lane lexical gate
3. assignment preference strengthening
4. tune aliases based on real observed failures

This keeps the change small and easy to reason about.

## Success Criteria
After this lands:

- keyboard videos should stop leaking into `Embedded Systems`
- terminal / Neovim videos should stop leaking into `macOS & Apple`
- `Watch` should still discover new creators, but only when the videos themselves are defensibly on-topic
- the system should be easier to tune without changing the schema
