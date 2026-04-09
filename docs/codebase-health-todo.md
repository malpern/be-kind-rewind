# Codebase Health TODO

Audit performed 2026-04-09. Organized by priority.

---

## P0 — Structural / Architecture

- [ ] **Break up OrganizerStore (God Object)**
  2,735 lines across 5 files, 65+ methods, 28+ properties. Handles database access,
  UI state, filtering, search, candidate discovery, sync, browser automation, and
  creator analytics in one class.
  - Extract `CandidateDiscoveryCoordinator` from `OrganizerStore+CandidateDiscovery.swift` (1,001 lines)
  - Extract `SyncCoordinator` from `OrganizerStore+Sync.swift` (228 lines)
  - Extract `CreatorAnalyticsProvider` from `OrganizerStore+CreatorAnalytics.swift` (113 lines)
  - Keep `OrganizerStore` as a thin facade delegating to these coordinators

- [ ] **Replace deprecated Alert API**
  `OrganizerView.swift:67-73` uses the old `Alert` struct with `.alert(item:)`.
  Migrate to `.alert(_:isPresented:actions:message:)`.

- [ ] **Fix `nonisolated(unsafe)` static cache in ClaudeClient**
  `ClaudeClient.swift:18` — `nonisolated(unsafe) private static var cachedKey` is a
  thread-unsafe shared mutable. Use an actor-isolated property or a lock.

- [ ] **Split VideoTaggerCommand.swift**
  1,293 lines in a single CLI command file. Break into subcommand files.

---

## P2 — Testability & Coverage

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

- [ ] **Replace silent `try?` calls with logged errors**
  `OrganizerStore+CandidateDiscovery.swift` has multiple `try?` calls that
  silently swallow errors. At minimum, log the error before discarding it.

---

## P3 — File Organization

- [ ] **Extract cell/header SwiftUI content from CollectionGridView.swift**
  2,225 lines with 11+ types. The cell SwiftUI body (`line 1868+`) and header
  SwiftUI body (`line 2036+`) can live in their own files.

- [ ] **Split TopicStore.swift by domain**
  1,500 lines covering CRUD, queries, sync queue, and candidates.
  Consider `TopicStore+Candidates.swift`, `TopicStore+Sync.swift`.

- [ ] **Split YouTubeClient.swift**
  1,014 lines. Consider separating read operations (fetch metadata, search)
  from write operations (add/remove playlist items).

- [ ] **Remove stale backup file**
  `docs/FlattenedGridView.swift.bak` is a leftover backup in the docs folder.

---

## P4 — Apple Best Practices

- [ ] **Document `@unchecked Sendable` safety invariants**
  `YouTubeAuthController.swift:143` — `OAuthLoopbackReceiver` uses
  `@unchecked Sendable` without documenting why it's safe. Add a comment
  explaining the threading guarantees.

- [ ] **Audit `nonisolated(unsafe)` on boundsObserver**
  `CollectionGridView.swift:1538` — verify the observer lifecycle is correct
  and document the safety rationale.

- [ ] **Add retry/backoff for network-dependent services**
  `YouTubeClient`, `BrowserSyncService`, and `DiscoveryFallbackService` have
  no retry logic on transient failures.

---

## P5 — Documentation

- [ ] **Add doc comments to OrganizerStore public API**
  40+ public properties and methods with no documentation. Prioritize
  `candidateVideosForTopic()`, `candidateVideosForAllTopics()`,
  `navigateToCreatorInWatch()`, `pageDisplayMode`, and state lifecycle.

- [ ] **Document CollectionGridView AppKit bridge architecture**
  2,225 lines with zero doc comments. Needs a file-level overview explaining
  the NSViewRepresentable → Coordinator → Cell → SwiftUI hosting chain.

- [ ] **Document TopicSidebar filtering logic** (623 lines, zero docs)

- [ ] **Document VideoInspector** (535 lines, zero docs)

- [ ] **Document PKCE OAuth flow in YouTubeOAuth.swift**
  The authorization code flow with PKCE is non-trivial and undocumented.

- [ ] **Add doc comments to remaining 20 undocumented UI files**
  At minimum, each file should have a one-line `///` comment on the main type
  explaining its role.
