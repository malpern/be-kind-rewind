# Codebase Health TODO

Audit performed 2026-04-09. Organized by priority.

---

## P0 — Structural / Architecture

- [x] **Replace deprecated Alert API**
- [x] **Fix `nonisolated(unsafe)` static cache in ClaudeClient** → `Mutex<String?>`
- [x] **Target macOS 15** (was macOS 14)
- [x] **Extract view models from OrganizerStore** → `OrganizerViewModels.swift` (336 lines)
- [x] **Split VideoTaggerCommand.swift** (1,293 → 51 lines main + 3 focused files)
- [ ] **Break up OrganizerStore further**
  Still ~1,100 lines. Candidate mutation methods and creator navigation
  logic could be extracted into focused extensions.

---

## P2 — Testability & Coverage

- [x] **Replace silent `try?` calls with logged errors** (12 calls)
- [x] **Add tests for BrowserSyncService** (4 tests)
- [x] **Add tests for DiscoveryFallbackService** (3 tests)
- [x] **Add tests for YouTubeSyncService** (6 tests)
- [x] **Add tests for ThumbnailCache** (4 tests)
- [x] **Make hard-coded dependencies injectable**
  - ThumbnailCache: cacheDir + URLSession injectable
  - YouTubeAuthController: tokenStore injectable

---

## P3 — File Organization

- [x] **Remove stale backup file** `docs/FlattenedGridView.swift.bak`
- [x] **Extract cell/header SwiftUI content from CollectionGridView** → `CollectionGridCellContent.swift`

---

## P4 — Apple Best Practices

- [x] **Document `@unchecked Sendable` safety invariants**
- [x] **Audit `nonisolated(unsafe)` on boundsObserver**

---

## P5 — Documentation

- [x] **Add doc comments to OrganizerStore public API**
- [x] **Document CollectionGridView AppKit bridge architecture**
- [x] **Document PKCE OAuth flow in YouTubeOAuth.swift**
- [x] **Add doc comments to all undocumented UI files** (17 files)
- [x] **Document TopicSidebar filtering logic**
- [x] **Document VideoInspector sections**

---

## Remaining (low priority, diminishing returns)

- [ ] **Split TopicStore.swift by domain** (1,500 lines)
  Requires widening column access from `private` to `internal`.
- [ ] **Split YouTubeClient.swift** (1,014 lines, read vs write)
- [ ] **Add retry/backoff for network-dependent services**
- [ ] **Add tests for YouTubeAuthController** (token refresh, error states)
