# Watch Experience Spec

## Status
Draft product spec for the `Watch` experience.

## Summary
`Watch` is a recent, topic-aware discovery feed for videos the user likely has not dealt with yet.

It should blend:
- recent videos from known topic creators
- recent videos from carefully admitted new creators that are on-topic or strongly adjacent

It should not feel like:
- a random shuffle
- an all-time backlog
- a weakly related adjacency dump
- a second copy of the saved library

## Product Promise
`Watch` shows recent, relevant videos you likely have not dealt with yet, mixing trusted known creators with a controlled amount of new discovery.

## Experience Goals
- Fresh: the default experience should feel current.
- Relevant: topic membership should be understandable and defensible.
- Novel: users should discover new creators and new videos, not only more of the same.
- Stable: counts, filters, and cards should all refer to the same underlying candidate pool.
- Legible: `By Topic` and `Show All` should be different presentations of the same feed universe, not different definitions of eligibility.

## Non-Goals
- Full historical recommendation backlog.
- Arbitrary randomization.
- User-managed query editing in V1.
- A live YouTube history scraper.

## Core Model
`Watch` uses one unified candidate pool per topic.

Each topic pool contains videos that are:
- recent enough to qualify for `Watch`
- not already watched, dismissed, or otherwise terminally processed
- relevant to the topic through known-creator evidence or strong new-discovery evidence

`Show All` is the deduplicated union of those same topic pools.

## Default Freshness Rule
The default `Watch` pool is recent-only.

Suggested default:
- recent window: last 30 days

This is a hard eligibility gate for the main `Watch` feed, not just a ranking hint.

Older items may be reintroduced later as a separate explicit lane or mode, but they should not silently dominate the default feed.

## Discovery Lanes
### 1. Known Creators
Videos from creators already strongly associated with the topic.

Properties:
- highest precision
- lower novelty
- still freshness-gated

### 2. New Finds
Videos from creators not yet established in the topic, but admitted because they have strong topic evidence.

Properties:
- higher novelty
- stricter admission rules
- still freshness-gated

## Creator Admission Rules
### Known creator lane
A creator qualifies if they already have enough saved videos in the topic or subtopics to be considered topic-native.

### New creator lane
A creator should only qualify if the system has strong evidence, such as:
- explicit query/search match for the topic
- multiple recent videos matching the topic
- strong adjacency through saved-library overlap with topic creators or subtopics

Weak or generic adjacency alone should not be enough.

## Eligibility Rules
A video belongs in `Watch` only if all of the following are true:
- within the recent window
- not explicitly watched
- not dismissed
- not already suppressed by imported watch history
- not obviously low-signal junk
- admitted through a known-creator or new-find lane

Soft `seen` signals like app opens should not hard-hide a video, but should reduce its ranking.

## Ranking Rules
Ranking should happen only after eligibility has been determined.

Signals:
- topic relevance
- freshness
- creator affinity
- creator novelty bonus for good new finds
- soft seen penalty for videos the user has already opened or repeatedly surfaced
- creator diversity penalty so one creator does not flood the feed

### Diversity rule
The system should allow:
- one or two strong recent videos from a creator

It should avoid:
- many old or middling videos from the same creator dominating the feed

## Presentation Modes
### By Topic
Shows one recent watch pool per topic.

Topic counts, creator-face counts, and creator rows must all reflect the exact same recent watch pool for that topic.

### Show All
Shows the deduplicated union of all topic watch pools.

`Show All` should:
- use the same eligibility rules as `By Topic`
- dedupe by `videoId`
- rerank globally

It should not:
- use a different freshness definition
- use a different creator count model
- show duplicate cards that appear in multiple topics

## Counts
In `Watch`, every count should mean:
- the number of recent, watch-eligible videos in the currently relevant pool

That means:
- topic count = recent watch-eligible videos for that topic
- creator count = recent watch-eligible videos for that creator in the current topic or current global watch scope
- subtopic count = recent watch-eligible videos mapped to that subtopic

It should never mean:
- all saved videos
- all-time creator totals
- all candidate backlog rows regardless of freshness

## Creator Faces
Creator faces in `Watch` should:
- represent creators present in the current watch pool
- show counts from the current watch pool
- be ordered by freshness first
- break ties with count and then stable name ordering

In `By Topic`, they reflect the selected topic's watch pool.

In `Show All`, they reflect the deduplicated global watch pool.

## Click Behavior
In `Watch`:
- clicking a creator face filters the current watch pool to that creator
- clicking the same creator again clears the filter
- the app must remain in `Watch`

In `Saved`:
- creator clicks keep their existing saved-library behavior

## Sidebar Behavior
In `Watch`:
- topic counts reflect recent watch-eligible videos
- creator rows reflect current watch creators and counts
- subtopic rows reflect current watch counts once candidate-to-subtopic mapping exists

Until true candidate-to-subtopic classification exists, subtopic counts may be approximate and should be treated as an implementation limitation, not the long-term model.

## Source Provenance
The system should internally track which lane produced a video:
- `known_creator`
- `new_find`
- later: `search`

This is primarily for ranking and debugging in V1.

User-facing provenance can be added later as subtle labels like:
- `Known Creator`
- `New Find`

## What `Watch` Is Not
`Watch` is not:
- “all unseen videos we know about”
- “all candidate rows we have ever archived”
- “all creators vaguely adjacent to the topic”

## Success Criteria
The user should feel that:
- most videos are recent
- the feed is on-topic
- familiar good creators appear quickly
- new creators show up often enough to be interesting
- one creator does not take over the page
- counts, faces, and filters all make sense together

## Open Questions
- Whether older “gems” should exist as a separate explicit lane later.
- How strict new-creator admission should be before the search-discovery lane is added.
- When candidate-to-subtopic classification should be added so watch subtopic counts become exact.
