# Codebase Health TODO

Audit refreshed 2026-04-12 after repo health review + design simplification pass.
This list only keeps issues that are still open.

---

## P0 — Responsiveness / Runtime

- [x] **Keep the package build green while offline-download work lands**
- [x] **Move startup thumbnail prefetch off the launch path**
- [x] **Stop sidebar search/filtering from doing per-topic DB reads**

- [ ] **Finish Watch render-path profiling and remove topic-boundary hitches**
  The remaining `Watch > By Topic` freeze at topic boundaries is still not
  fully isolated.
  - Capture `flushIfReady` / header refresh / viewport timings during a real stall
  - Sample the process while frozen
  - Remove any remaining full-grid or sidebar thrash at topic transitions

---

## P1 — Structural / Architecture

- [x] **Split `TopicStore.swift` by domain** → `+SeenHistory`, `+Sync`
- [x] **Split `YouTubeClient.swift` into read/search/write** → `+Read`, `+Search`, `+Write`
- [x] **Split `CollectionGridView.swift` into smaller files**
  Extracted: ActionSupport, CommandObservers, ContextMenuBuilder,
  HeaderModelBuilder, PlaylistMenus, SectionFactory, CellContent.
  Remaining ~1,300 lines is the irreducible NSViewRepresentable bridge +
  Coordinator (data source, delegate, layout delegate). Further splitting
  has diminishing returns since these methods share Coordinator state.

- [ ] **Break up OrganizerStore further**
  Still ~1,500 lines covering property declarations, init, loading,
  video lookup, topic CRUD, and AI operations. Already has 10 extensions.
  Next candidates for extraction:
  - Topic CRUD (rename, delete, split, suggest) → `+TopicCRUD`
  - AI operations (split, suggest) → `+AIOperations`

---

## P1 — Product / macOS Fit

- [ ] **Stabilize Watch topic headers while background refresh continues**
  The visible topic's face pile/order should not churn just because
  unrelated topics complete refresh in the background.
  - Make visible-topic header data topic-local and stable for a refresh cycle
  - Only update a topic header when that topic's own underlying pool changes

---

## P2 — Packaging / Reliability

- [ ] **Stop depending on runtime `npx` installs for browser fallback**
  `BrowserSyncService` still shells out through `npx --package playwright ...`.
  Options: bundle the dependency, preflight at startup, or document clearly.

- [x] **Replace silent `try?` sites that still hide real failures**
- [x] **Fix `nonisolated(unsafe)` static cache in `ClaudeClient`**
  Already uses `Mutex<String?>` from the Synchronization framework — safe.

- [ ] **Reduce ad-hoc concurrency escape hatches in UI/integration code**
  One remaining `nonisolated(unsafe)` in `CollectionGridAppKit.swift` for
  the NotificationCenter bounds observer token — this is the correct
  pragmatic pattern for observer teardown in `deinit` (which is
  nonisolated by design). NotificationCenter.removeObserver is thread-safe.
  No further action needed unless Swift introduces a better pattern.

---

## P2 — Testability & Coverage

- [ ] **Add focused tests for `YouTubeAuthController`**
  UI-facing connect/reconnect state, refresh/error transitions.

- [x] **Add stronger behavior tests for `BrowserSyncService`**
- [x] **Add download manager tests** (`VideoDownloadManagerTests`)

- [ ] **Add integration-style tests for Watch render/selection behavior**
  Current tests cover store logic, but not viewport topic updates,
  sidebar follow behavior, or section-generation churn during refresh.

- [ ] **Make remaining hard-coded dependencies injectable**
  Auth/token store wiring, browser/process runners.

---

## P3 — Documentation

- [x] **Add file-level overview comments for complex files**
  - `OrganizerStore.swift`
  - `OrganizerStore+CandidateDiscovery.swift`
  - `TopicSidebar.swift`
  - `VideoInspector.swift`
  - `CollectionGridView.swift`
  - `CreatorDetailView.swift`
