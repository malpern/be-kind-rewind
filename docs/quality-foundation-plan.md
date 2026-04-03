# Quality Foundation Plan

## Goal

Raise confidence in the codebase without slowing down iteration. For this project, the target is:

- fast to change
- flexible enough to keep evolving
- stable in the places users feel breakage
- documented enough that future work starts from context instead of guesswork

This is not an enterprise process plan. It is a small-project quality plan.

## Principles

- Prefer targeted coverage over vanity coverage.
- Test logic-heavy code first, not UI pixels first.
- Write assertions that would fail for the bug you are trying to prevent.
- Document decisions that change how people work on the codebase.
- Add process only when it saves time or prevents repeated mistakes.

## Current Gaps

- Tests cover only `TaggingKit`.
- Coverage is concentrated in `TopicStore`; several newer files have no coverage.
- `VideoTagger` CLI behavior is effectively untested.
- `VideoOrganizer` has no unit-level safety net for its pure logic.
- Some tests check counts or non-crashing behavior without asserting the important state change.
- README is product-focused, but contributor and maintenance workflows are under-documented.
- Internal docs are strong on design exploration but thin on day-to-day engineering expectations.

## What "Good" Looks Like

Within the next few rounds of work, aim for:

- reliable tests around persistence, parsing, classification plumbing, and CLI commands
- extracted pure functions/view models from app code where logic is worth testing
- stronger assertions in existing tests
- a short contributor workflow doc
- consistent expectations for when to add tests and docs

## Execution Plan

### Phase 1: Tighten the Existing Base

1. Strengthen current `TaggingKitTests`.
2. Replace weak "does not crash" checks with assertions on returned values, thrown errors, and persisted state.
3. Add regression tests for recent schema/channel work in `TopicStore`.
4. Add coverage reporting to the normal local workflow with `swift test --enable-code-coverage`.

**Target outcomes**

- existing tests become harder to pass accidentally
- new storage and metadata code gets a safety net
- contributors can see real coverage numbers locally

### Phase 2: Add CLI Tests

1. Create a `VideoTaggerTests` target.
2. Test argument parsing, command validation, and file-path/db-path behavior.
3. Prefer extracting command-side logic into small testable functions rather than shelling out when possible.
4. Cover user-visible command output only where it encodes behavior.

**Priority areas**

- inventory loading paths
- missing argument / invalid input handling
- topic rename / merge / split flows
- sync-plan related commands

### Phase 3: Add Testable App Logic

1. Identify pure logic in `VideoOrganizer` that can be tested without UI harnesses.
2. Extract narrow helpers where needed instead of trying to unit test SwiftUI/AppKit directly.
3. Add a `VideoOrganizerTests` target for:
   - search parsing and matching
   - filtering and sorting
   - section/group derivation
   - keyboard-navigation math
   - formatting helpers that drive user-visible state

**Rule**

Do not build elaborate UI testing infrastructure until pure logic coverage is in place.

### Phase 4: Documentation Baseline

1. Add `docs/development.md` for local setup and maintenance.
2. Document:
   - how to build and run the app
   - how to run tests and coverage
   - required API keys and where they are loaded from
   - where the SQLite database lives
   - where inventory snapshots come from
3. Keep the README short and product-facing; put contributor details in `docs/`.

### Phase 5: Lightweight Quality Guardrails

1. Treat warnings in touched files as worth fixing when they are cheap and local.
2. For logic changes, require either tests or a written reason they are not practical.
3. For bug fixes, prefer adding a regression test before or with the fix.
4. For larger design changes, add or update an ADR/spec only if it changes future decisions.

## Testing Strategy by Area

## `TaggingKit`

Highest priority for broad coverage. It owns persistence, parsing, API clients, and classification plumbing.

- `TopicStore`: CRUD, migrations, topic/subtopic behavior, channel joins, sync collapse, edge cases
- `InventoryLoader`: malformed JSON, missing files, invalid fields, latest-run discovery
- `ClaudeClient`: request construction, error mapping, response parsing
- `YouTubeClient`: formatting helpers, request/response parsing, batching behavior
- `TopicSuggester`: prompt shaping, parsing model output, failure handling

## `VideoTagger`

Moderate priority. User-facing automation surface with meaningful behavior.

- argument parsing
- validation
- command-to-store wiring
- output for critical user decisions

## `VideoOrganizer`

Selective priority. Focus on logic, not view snapshots.

- search and filtering
- grouping and section derivation
- creator/subtopic selection rules
- keyboard movement rules
- sort behavior

Avoid heavy snapshot testing unless a specific UI bug keeps recurring.

## Assertion Guidelines

- Prefer exact equality over broad truthy assertions.
- Assert the user-visible or persisted effect, not just intermediate counts.
- For thrown errors, verify the error type and, when stable, the important associated data.
- Use `#require` when a later assertion depends on earlier lookup success.
- When testing collections, assert both count and identity/order when order matters.
- Add one regression-style assertion per bug fix when possible.

## Documentation Plan

Keep docs small and purpose-specific.

- `README.md`: what the project is, how to build/run at a high level
- `docs/development.md`: contributor workflow and environment
- `docs/quality-foundation-plan.md`: this roadmap
- `docs/agent-engineering-guide.md`: standing rules for humans and agents writing code
- ADR/spec docs: only for changes with architectural or product-design consequences

## Non-Goals

- chasing 100% coverage
- mandatory snapshot tests everywhere
- required mocks for every dependency
- broad abstraction layers "for future flexibility"
- CI/process complexity that exceeds the scale of the project

## Working Standard

Before merging a meaningful change, the default bar should be:

- the code is simpler or clearer than before
- the important behavior is tested, or explicitly hard to test for a good reason
- assertions are specific enough to catch the intended regression
- docs are updated if the change affects setup, workflow, architecture, or operator knowledge
- no obvious overengineering was introduced in the name of quality
