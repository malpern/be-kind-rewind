# Watch Low-Cost LLM Categorization Plan

## Status
Future plan.

## Summary
The current `Watch` categorization fix is intentionally rule-based:

- topic vocabulary
- subtopic vocabulary
- small alias lists
- stricter admission for adjacent and search lanes

That is the right short-term solution because the current failures are mostly obvious precision problems.

Later, we may want to add a low-cost LLM categorization layer for cases where lexical matching is not good enough.

The goal is not to replace the current gate. The goal is to improve ambiguous or subtle topic assignment without turning `Watch` into a slow, expensive classification pipeline.

## Goals
- Improve topic assignment for ambiguous videos where keywords are insufficient.
- Keep the current lexical gate as the cheap first pass.
- Use a low-cost model only for a narrow subset of videos that need disambiguation.

## Non-Goals
- No LLM call for every Watch candidate.
- No replacement of the current rule-based admission gate.
- No user-managed prompt or category editor.
- No requirement for online classification before Watch can render.

## When This Becomes Worth Doing
We should only add this after the current lexical gate has been observed in practice.

Signals that justify an LLM layer:

- obvious low-quality topic leakage is mostly gone
- remaining errors are semantic rather than lexical
- many failures look like:
  - human can tell the right topic from the title/context
  - keyword/alias matching still cannot

Examples:

- `macOS` vs `terminal` vs `developer workflow`
- `embedded systems` vs `electronics` vs `home automation`
- `AI coding tools` vs `AI models` vs `productivity`

## Proposed Role of the LLM
Use the LLM only as a selective disambiguation pass.

Suggested flow:

1. lexical/topic gate runs first
2. if one clear topic wins, stop
3. if the video is admissible to multiple nearby topics or has weak evidence, send it to a low-cost LLM classifier
4. store the chosen topic in memory or cache it locally for reuse

This keeps cost and latency bounded.

## Candidate Inputs
The classifier should use only lightweight inputs already available:

- title
- channel name
- matched search query, if any
- topic names
- subtopic names
- short provenance summary

Optional later:

- short channel description
- normalized topic aliases

Do not require transcript fetching in the first version.

## Output Shape
The model should return structured output like:

- best topic
- optional confidence
- short reason

Example shape:

- `topic_id`
- `confidence`
- `reason`

This should stay machine-friendly and easy to cache.

## Model Strategy
Prefer a low-cost model suitable for repeated small classifications.

Requirements:

- cheap
- fast
- deterministic enough for repeatable behavior
- strong enough to distinguish nearby technical topics

This should be treated as a small classification utility, not a general chat workflow.

## Caching Strategy
If we add an LLM classifier, cache results locally.

Good cache key candidates:

- `videoId`
- topic candidate set hash
- title
- channelId

At minimum:

- do not reclassify the same video repeatedly if the title and candidate topic set have not changed

## Rollout Strategy
### Phase 1
Stay entirely lexical/rule-based.

### Phase 2
Add logging/metrics for unresolved ambiguous topic assignments:

- videos admissible to multiple topics
- videos admitted weakly
- videos manually identified as misplaced

### Phase 3
Add optional low-cost LLM categorization only for:

- ambiguous multi-topic candidates
- weak adjacent/search matches

### Phase 4
If it works well, expose provenance in debug output:

- `lexical`
- `adjacent`
- `search`
- `llm_disambiguated`

## Why This Is Better Than Starting With LLM
The current issue is still mostly bad admission precision.

That means:

- the cheap fix should come first
- the LLM should be reserved for hard cases

This avoids:

- unnecessary cost
- latency on every refresh
- extra failure modes during Watch loading

## Success Criteria
If and when this is implemented, it should:

- reduce the remaining subtle misclassifications
- not meaningfully slow Watch refresh
- not require a schema rewrite
- remain a second-pass disambiguation layer rather than a replacement for the current rule-based system
