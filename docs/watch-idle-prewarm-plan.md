# Watch Idle Prewarm Plan

## Status
Draft implementation plan.

## Summary
`Watch` should feel fast even before the user clicks it.

The most pragmatic way to improve that is to opportunistically refresh a small amount of `Watch` data while the user is still on `Saved`, but only when the app is idle enough that the extra work will not interfere with normal interaction.

This plan keeps the idea intentionally narrow:

- no OS-level background scheduling
- no persistent job system
- no full-library crawl in the background

Instead, the app should quietly prewarm a small number of likely Watch topics during short idle windows.

## Goals
- Reduce the amount of work required at the moment the user clicks `Watch`.
- Keep the UI responsive and avoid stealing resources while the user is actively interacting.
- Reuse existing Watch discovery code paths instead of introducing a second discovery architecture.

## Non-Goals
- No always-on background crawler.
- No macOS idle API integration.
- No menu bar daemon or launch agent.
- No user-configurable scheduler in V1.
- No big visible progress UI for background prewarming.

## Product Behavior
While the user is in `Saved`, the app may quietly refresh a small number of Watch topic pools if:

- the app has been idle for a short time
- no explicit Watch refresh is already running
- no heavier sync work should take priority

The user should not see:

- a large Watch HUD
- mode switches
- page flicker
- heavy CPU spikes during active use

The only user-visible result should be:

- `Watch` feels faster when they later switch to it

## Trigger Conditions
Idle prewarm should run only when all of these are true:

1. page mode is `Saved`
2. no explicit Watch refresh task is running
3. the app has been interaction-idle for a minimum threshold
4. no browser sync or heavy queue processing is actively running
5. the prewarm budget for the current idle window has not been exhausted

Suggested initial idle threshold:

- 15 seconds without interaction

## What Counts as Interaction
Any of these should reset the idle timer:

- scrolling the grid
- changing selection
- changing topic
- changing search text
- changing sort/grouping
- opening context menus
- entering `Watch`

This keeps prewarming from competing with active UI work.

## Prewarm Scope
Keep the first version extremely small.

Per idle window:

- refresh at most 1 to 2 topics

Per topic:

- reuse the normal `ensureCandidates(for:)` path
- update the same stored candidates and watch pools as a normal Watch refresh

No separate discovery path should be created.

## Topic Priority
When choosing topics to prewarm, use this order:

1. selected topic in `Saved`
2. recently viewed topics
3. topics with stale cached Watch candidates
4. topics with historically high recent watch yield

In the first version, it is fine to stop after:

- selected topic
- then one additional stale topic

## Resource Guardrails
To keep this from feeling expensive:

- only run one topic refresh at a time
- yield after each topic
- stop immediately if user interaction resumes
- skip prewarm when explicit sync/browser work is active
- never prewarm every topic in one idle session

## UI Behavior
V1 should be almost silent.

Recommended behavior:

- no large HUD
- optionally a subtle internal state only for debugging/logging

If a user later switches to `Watch`, they should simply benefit from warmer caches.

## Store Changes
Add lightweight state in `OrganizerStore`:

- last user interaction timestamp
- idle prewarm task
- optional set of topics already prewarmed in this idle window

Also add one helper:

- `noteUserInteraction()`

This should be called from existing UI event paths that already know when the user interacts.

## Scheduling Model
Use a simple in-app task model:

1. user interaction updates `lastUserInteractionAt`
2. a lightweight timer or delayed task checks whether the app is now idle enough
3. if yes, start a small prewarm task
4. if interaction resumes, cancel the task

This is sufficient for V1.

## Implementation Steps
### Step 1. Add idle interaction tracking
Track the last time the user interacted with the app.

### Step 2. Add a cancellable prewarm task
Only one prewarm task should exist at a time.

If the user resumes interacting:

- cancel it immediately

### Step 3. Add topic selection for prewarm
Implement a simple topic chooser:

- selected topic first
- then one stale fallback topic

### Step 4. Reuse existing topic refresh logic
Call the same candidate refresh path already used by `Watch`.

This keeps behavior consistent and avoids duplicated discovery logic.

### Step 5. Keep Watch UI silent
Do not surface the main Watch HUD for background prewarm.

At most, log the work internally.

## Likely Files To Change
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/OrganizerStore.swift`
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/OrganizerStore+CandidateDiscovery.swift`
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/CollectionGridView.swift`
- `/Users/malpern/local-code/be-kind-rewind/Sources/VideoOrganizer/OrganizerView.swift`

## Test Plan
### Logic tests
Add tests for:

- idle prewarm does not start while page mode is `Watch`
- idle prewarm chooses selected topic first
- idle prewarm cancels on user interaction
- idle prewarm does not run while an explicit Watch refresh is active

### Manual validation
1. Stay on `Saved`
2. stop interacting for ~15 seconds
3. let one or two topics prewarm quietly
4. switch to `Watch`

Expected:

- lower startup cost
- fewer visible topic refreshes needed immediately
- no obvious UI disturbance while prewarming happened

## Success Criteria
- `Watch` feels faster when entered after a quiet period on `Saved`
- the app stays responsive while prewarming occurs
- the user is not distracted by background work
- the implementation remains small and local to existing Watch refresh code
