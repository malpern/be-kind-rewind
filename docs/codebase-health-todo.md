# Codebase Health TODO

Audit refreshed 2026-04-12 after a repo health review.
This list only keeps issues that are still open.

---

## P0 — Responsiveness / Runtime

- [x] **Keep the package build green while offline-download work lands**
  The current `VideoDownloadManager.swift` integration is not compile-safe yet:
  `swift test` currently fails on a main-actor isolation violation while parsing
  yt-dlp progress updates from a detached task.
  - Fix actor isolation around progress parsing / state updates
  - Add at least one focused test or smoke-check path for the download manager
  - Do not leave partially integrated feature work in the default build path

- [x] **Move startup thumbnail prefetch off the launch path**
  `Sources/VideoOrganizer/VideoOrganizerApp.swift` still gathers every saved video ID
  at startup and immediately calls `ThumbnailCache.prefetch(...)`.
  - Narrowed to selected-topic prefetch from `OrganizerView`
  - Bulk warmup can move to idle/prewarm later

- [x] **Stop sidebar search/filtering from doing per-topic DB reads**
  `Sources/VideoOrganizer/TopicSidebar.swift` computes `filteredTopics` by calling
  `store.videosForTopic(topic.id)` for every topic during view recomputation.
  - Materialized topic search corpus in `OrganizerStore`
  - Sidebar now renders from cached topic/search state only

- [ ] **Finish Watch render-path profiling and remove topic-boundary hitches**
  We now have some timing logs, but the remaining `Watch > By Topic` freeze at
  topic boundaries is still not fully isolated.
  - Capture `flushIfReady` / header refresh / viewport timings during a real stall
  - Sample the process while frozen
  - Remove any remaining full-grid or sidebar thrash at topic transitions

---

## P1 — Structural / Architecture

- [ ] **Break up OrganizerStore further**
  `OrganizerStore.swift` is still the main “god object” for:
  - selection/filter state
  - cached maps
  - Watch state
  - sync orchestration
  - some UI-facing behavior

  Keep shrinking it toward a facade:
  - Extract more of Watch state/rebuild logic behind a dedicated coordinator/model
  - Keep sync orchestration separated in `OrganizerStore+Sync.swift`
  - Avoid adding more direct UI policy into the root store

- [ ] **Split `CollectionGridView.swift` into smaller files**
  Still ~2,100+ lines and handles:
  - SwiftUI wrapper
  - NSViewRepresentable bridge
  - AppKit coordinator/data source/delegate
  - container view
  - keyboard handling
  - header/cell configuration

  Priority extractions:
  - coordinator support/helpers
  - container view / scroll observer code
  - header model + header view content

- [x] **Split `TopicStore.swift` by domain**
  Still ~1,500 lines covering:
  - topics and assignments
  - playlist state
  - candidate queries
  - sync queue
  - seen history / excluded creators

  Likely split:
  - `TopicStore+Candidates.swift`
  - `TopicStore+Sync.swift`
  - `TopicStore+SeenHistory.swift`

- [x] **Split `YouTubeClient.swift` into read/search/write areas**
  Still ~1,000 lines and mixes:
  - metadata fetch
  - playlist fetch
  - search
  - write operations
  - retry/backoff/error decoding

---

## P1 — Product / macOS Fit

- [ ] **Stabilize Watch topic headers while background refresh continues**
  The visible topic’s face pile/order should not churn just because unrelated topics
  complete refresh in the background.
  - Make visible-topic header data topic-local and stable for a refresh cycle
  - Only update a topic header when that topic’s own underlying pool changes

---

## P2 — Packaging / Reliability

- [ ] **Stop depending on runtime `npx` installs for browser fallback**
  `BrowserSyncService` still shells out through `npx --package playwright ...` at runtime.
  That is brittle for a signed desktop app and unfriendly to offline or flaky-network use.
  Options:
  - bundle/ship the Node runtime dependency explicitly
  - preflight and validate runtime dependencies at app startup/settings
  - at minimum, document and surface dependency failures more clearly

- [x] **Replace silent `try?` sites that still hide real failures**
  Several remain in production code where failure matters for diagnosability:
  - client/config initialization in `OrganizerStore`
  - file/JSON loads in `YouTubeClient` / `ClaudeClient`
  - process/session probing in `BrowserSyncService`
  - file/process persistence in `VideoDownloadManager`

  Prefer:
  - explicit logging
  - or fallback with an audit trail

- [ ] **Reduce ad-hoc concurrency escape hatches in UI/integration code**
  There are still a few risky patterns around actor boundaries and lifecycle:
  - detached/background tasks that reach back into main-actor-owned state
  - `nonisolated(unsafe)` observer state in `CollectionGridAppKit`
  - process callbacks that rely on manual `MainActor.run` hops

  Prefer:
  - actor-safe helper types or dedicated workers
  - fewer detached tasks in UI-adjacent code
  - compile-time isolation guarantees over comments/convention

- [ ] **Fix `nonisolated(unsafe)` static cache in `ClaudeClient`**
  The current shared mutable cache is still a concurrency risk and should be replaced
  with an actor-safe or locked approach.

---

## P2 — Testability & Coverage

- [ ] **Add focused tests for `YouTubeAuthController`**
  Still a gap:
  - UI-facing connect/reconnect state
  - refresh/error transitions
  - onboarding/settings integration behavior

- [x] **Add stronger behavior tests for `BrowserSyncService`**
  Basic type/result coverage exists now, but not enough around:
  - command construction
  - process failure handling
  - artifact-dir / payload behavior

- [ ] **Add integration-style tests for Watch render/selection behavior**
  Current tests cover store logic well, but not enough for:
  - `Watch > By Topic` viewport topic updates
  - sidebar follow behavior
  - creator header stability
  - section-generation churn when refreshing

- [ ] **Make remaining hard-coded dependencies injectable**
  Still useful for testability:
  - auth/token store wiring
  - browser/process runners
  - any remaining network session or shell execution seams

---

## P3 — Documentation

- [ ] **Add file-level overview comments where the complexity is now highest**
  Highest-value targets:
  - `OrganizerStore.swift`
  - `OrganizerStore+CandidateDiscovery.swift`
  - `TopicSidebar.swift`
  - `VideoInspector.swift`
  - `YouTubeClient.swift`
