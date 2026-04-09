# Codebase Health TODO

Audit performed 2026-04-09. Organized by priority.

---

## P0 — Structural / Architecture

- [x] **Replace deprecated Alert API**
  `OrganizerView.swift` — migrated to `.alert(_:isPresented:actions:message:)`.

- [x] **Fix `nonisolated(unsafe)` static cache in ClaudeClient**
  Replaced with `Mutex<String?>` from Synchronization framework.

- [x] **Target macOS 15** (was macOS 14)
  Updated `Package.swift` platforms to `.macOS(.v15)`.

- [x] **Extract view models from OrganizerStore**
  Moved 336 lines of enums/structs to `OrganizerViewModels.swift`.

- [ ] **Break up OrganizerStore further (God Object)**
  Still 1,100+ lines with 65+ methods. Consider extracting:
  - Candidate mutation methods → `OrganizerStore+CandidateMutations.swift`
  - Creator navigation logic → standalone coordinator
  - Playlist save/remove operations → dedicated helper

- [ ] **Split VideoTaggerCommand.swift**
  1,293 lines in a single CLI command file. Break into subcommand files.

---

## P2 — Testability & Coverage

- [x] **Replace silent `try?` calls with logged errors**
  12 calls converted to do/catch with AppLogger in OrganizerStore,
  Sync, SeenHistory, and CandidateDiscovery.

- [ ] **Add tests for BrowserSyncService** (254 lines, zero tests)
  Orchestrates an external Node.js process. At minimum, test the command
  construction and output parsing with mock process execution.

- [ ] **Add tests for DiscoveryFallbackService** (117 lines, zero tests)
  Orchestrates an external Python script. Test error handling and result parsing.

- [ ] **Add tests for ThumbnailCache** (76 lines, zero tests)
  Make `URLSession` injectable so network calls can be mocked.

- [ ] **Add tests for YouTubeAuthController** (309 lines, zero tests)
  OAuth UI flow. Test token refresh logic and error states.

- [ ] **Add tests for YouTubeSyncService** (105 lines, zero tests)
  Playlist sync operations — test the sync plan and conflict resolution.

- [ ] **Make hard-coded dependencies injectable**
  - `YouTubeAuthController.swift:10` — `YouTubeOAuthTokenStore()` created inline
  - `ThumbnailCache` — creates its own `URLSession` internally
  These block unit testing of the consuming types.

---

## P3 — File Organization

- [x] **Remove stale backup file** `docs/FlattenedGridView.swift.bak`

- [ ] **Extract cell/header SwiftUI content from CollectionGridView.swift**
  2,225 lines with 11+ types. The cell SwiftUI body and header
  SwiftUI body can live in their own files.

- [ ] **Split TopicStore.swift by domain**
  1,500 lines covering CRUD, queries, sync queue, and candidates.
  Requires widening column access from `private` to `internal`.

- [ ] **Split YouTubeClient.swift**
  1,014 lines. Consider separating read operations (fetch metadata, search)
  from write operations (add/remove playlist items).

---

## P4 — Apple Best Practices

- [x] **Document `@unchecked Sendable` safety invariants**
  Added safety documentation to `OAuthLoopbackReceiver` in
  `YouTubeAuthController.swift`.

- [x] **Audit `nonisolated(unsafe)` on boundsObserver**
  Added safety rationale comment in `CollectionGridView.swift`.

- [ ] **Add retry/backoff for network-dependent services**
  `YouTubeClient`, `BrowserSyncService`, and `DiscoveryFallbackService` have
  no retry logic on transient failures.

---

## P5 — Documentation

- [x] **Add doc comments to OrganizerStore public API**
  Added class-level doc, extension index, and key property/method docs.

- [x] **Document CollectionGridView AppKit bridge architecture**
  Added file-level architecture overview explaining the full hosting chain.

- [x] **Document PKCE OAuth flow in YouTubeOAuth.swift**
  Added step-by-step flow documentation on `YouTubeOAuthService`.

- [x] **Add doc comments to all undocumented UI files**
  All 17 UI files now have at least a one-line type-level doc comment.

- [ ] **Document TopicSidebar filtering logic** (623 lines)
  Internal methods that build the sidebar sections need explanation.

- [ ] **Document VideoInspector** (535 lines)
  The multi-section inspector layout logic is undocumented.
