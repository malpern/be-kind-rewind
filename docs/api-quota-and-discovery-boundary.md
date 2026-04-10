# API Quota And Discovery Boundary

## Intent

Treat the YouTube Data API as a scarce daily resource.

The app should:

- prefer scrape and RSS discovery paths first
- estimate YouTube API quota usage and remaining daily budget
- ask the user before spending quota on fallback discovery
- log both scrape behavior and API behavior for telemetry
- keep a clean boundary between scrape-backed and API-backed discovery paths

## Product Rules

1. Scrape and RSS are the default for read-heavy discovery.
2. API fallback is opt-in, not automatic.
3. Approval UI must show:
   - why scrape failed
   - the estimated quota cost of the fallback
   - estimated remaining quota for the current Pacific day
4. API use and scrape use must both be logged.
5. Quota estimates reset at midnight Pacific.

## Boundary

Discovery code should conceptually separate into:

- scrape providers
  - channel archive scraping
  - search scraping
  - channel icon scraping
- API providers
  - channel archive lookup
  - search lookup
  - channel/icon metadata lookup
  - playlist reads and writes
- policy layer
  - quota ledger
  - approval gating
  - telemetry

The current codebase is still mid-refactor, but the intended ownership is:

- `TaggingKit`
  - provider implementations
  - quota ledger
  - transport-level telemetry
- `VideoOrganizer`
  - approval UX
  - settings presentation
  - app-specific policy wiring for Watch discovery

## Current Quota Model

The app uses estimated YouTube units per request type:

- `search.list`: 100
- `videos.list`: 1
- `channels.list`: 1
- channel archive refresh fallback prompt: 6
- `playlistItems.list`: 1
- `playlistItems.insert`: 50
- `playlistItems.delete`: 50

These are estimates for user-facing budgeting and telemetry, not authoritative server-side counters.

## Current Approval Scope

Approval is currently required before these Watch discovery fallbacks:

- search fallback from scrape to API
- channel archive fallback from scrape/RSS to API
- channel icon fallback from scrape to API

Additional current controls:

- search API fallback is disabled by default and must be enabled in Settings
- each Watch refresh pass has a configurable aggregate API budget ceiling
- approvals can be remembered for the rest of the current refresh pass

For multi-step fallback flows, prompts should use a conservative estimate rather than the cost
of only the first request. Channel archive refresh now uses a 6-unit estimate to account for the
initial uploads lookup plus likely playlist and metadata follow-up calls.

## Follow-Up Work

- move discovery execution behind explicit provider protocols
- stop broad Watch refresh from re-running full topic sets unnecessarily
- add tests for approval denial and quota snapshot math
- add per-feature UI copy for fallback prompts
- make discovery telemetry browsable/filterable in Settings
