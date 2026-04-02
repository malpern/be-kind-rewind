# ADR-001: Replace SwiftUI Grid with NSCollectionView for Sidebar Scroll Navigation

**Status:** Accepted  
**Date:** 2026-04-02  
**Deciders:** Micah Alpern, with input from senior SwiftUI advisor  

## Context

The Be Kind, Rewind video organizer app has a three-pane layout: sidebar (topic list), center (video thumbnail grid), and inspector. Clicking a topic in the sidebar should scroll the center grid to that topic's section. The grid displays ~5,000 videos across ~22 topic sections using `ScrollView > LazyVStack(pinnedViews: [.sectionHeaders]) > Section > LazyVGrid`.

This scroll navigation has never worked reliably. Far-away sections either don't scroll at all, scroll to the wrong section, or crash the app.

## Decision

Replace the center grid pane's SwiftUI `LazyVStack + LazyVGrid` with an `NSCollectionView` wrapped in `NSViewRepresentable`. Keep the sidebar, inspector, navigation structure, and all app state in SwiftUI.

## Alternatives Considered

### 1. `ScrollPosition.scrollTo(id:)` on various target views
**Tried:** Zero-height anchors, Section `.id()`, first video `.id()`, Section header `.id()`. Tested on both nested `LazyVGrid` and flattened `HStack` row structures.  
**Result:** Does not work for far-away targets. `LazyVStack` does not realize off-screen views, so SwiftUI has no geometry to scroll to. This failed identically across both nesting structures, confirming the limitation is lazy realization itself.

### 2. `ScrollPosition.scrollTo(y: estimatedOffset)` with height estimation
**Tried:** Pre-compute cumulative section heights from thumbnail size, column count, and metadata settings. Two-phase approach: Y-offset jump, then ID-based refinement.  
**Result:** Gets within 1 section of the target. Per-row height estimates have ~2-5% error that compounds across 22 sections. Best result was 5/7 sections correct. The remaining error is layout drift in SwiftUI's internal spacing, not a modeling bug in our code.  
**Also discovered:** `containerWidth` was stuck at its default (800px) because `GeometryReader` preferences deliver asynchronously after layout. Fixed with `onGeometryChange`, but this class of timing bug is inherent to the approach.

### 3. NSScrollView interop (drive SwiftUI's underlying scroll view from AppKit)
**Tried:** Capture enclosing `NSScrollView` via `NSViewRepresentable`, call `clipView.scroll(to:)`.  
**Result:** Crashes with `_postWindowNeedsUpdateConstraints` recursion. AppKit and SwiftUI fight over scroll state ownership. `DispatchQueue.main.async`, `Task { @MainActor }`, and other deferral strategies reduce frequency but do not prevent the crash. A senior advisor characterized this as a framework bug, not something timing hacks can solve.

### 4. Flattened rows (replace LazyVGrid with explicit HStack rows)
**Tried:** Each grid row as a direct child of `LazyVStack` instead of nested inside `LazyVGrid`. Makes row heights deterministic and scroll targets direct children.  
**Result:** `scrollTo(id:)` still fails (lazy realization is the blocker, not nesting depth). Combined with `scrollTo(y:)`, achieves 3/5 correct — marginal improvement over the nested structure but still off by 1 section for middle targets.

### 5. `List` with `NSOutlineView` backing
**Considered but rejected.** `List` gives reliable row scrolling but doesn't support grid layouts with pinned section headers. Wrong primitive for a thumbnail grid.

### 6. NSCollectionView (chosen)
`NSCollectionView` natively supports: grid layouts with section headers (including sticky/pinned), programmatic scrolling via `scrollToItems(at:scrollPosition:)` that works for any distance, efficient cell recycling for large datasets, and compositional layouts. It is the standard AppKit solution for exactly this use case.

## Consequences

### Positive
- **Guaranteed scroll accuracy** — `scrollToItems(at:scrollPosition:)` works regardless of distance or realization state
- **No crash risk** — AppKit is sole owner of scroll position, no mixed-ownership constraint recursion
- **Proven at scale** — NSCollectionView handles 5,000+ items routinely
- **Pinned section headers** — built into the layout system, not a workaround

### Negative
- **Significant rewrite** — the center grid view, cell rendering, and scroll control must be reimplemented in AppKit
- **Two UI paradigms** — sidebar stays SwiftUI, grid becomes AppKit. Data flow requires explicit bridging.
- **Cell rendering options** — either rewrite `VideoGridItem` in AppKit, or wrap each SwiftUI card in `NSHostingView` (adds per-cell overhead)
- **Harder to maintain** — future grid UI changes require AppKit knowledge
- **Animation bridging** — SwiftUI's `withAnimation` won't work across the boundary

### Scope
- Replace ONLY `OrganizerView`'s center content (currently `AllVideosGridView` or `FlattenedGridView`)
- Keep `NavigationSplitView`, `TopicSidebar`, `VideoInspector`, and all `@Observable` state in SwiftUI
- Feed precomputed section/item models from existing `OrganizerStore`
- Bridge selection changes (`selectedVideoId`, `selectedTopicId`) back to SwiftUI state
- Preserve accessibility identifiers for automated testing with Peekaboo

## Evidence

| Experiment | Mechanism | Accuracy | Crashes | Verdict |
|---|---|---|---|---|
| scrollTo(id:) nested | ID on lazy children | 0/7 far targets | No | Failed |
| scrollTo(id:) flattened | ID on direct children | 0/5 far targets | No | Failed |
| scrollTo(y:) nested | Y-offset estimation | 5/7 | Intermittent | Partial |
| scrollTo(y:) flattened | Deterministic row heights | 3/5 | No | Partial |
| NSScrollView interop | clipView.scroll(to:) | N/A | Always | Failed |

All SwiftUI scroll APIs have been exhausted. The limitation is fundamental to `LazyVStack`'s design — it trades layout correctness for performance by not computing geometry for off-screen children.

## References
- Apple docs: [scrollPosition(id:anchor:)](https://developer.apple.com/documentation/SwiftUI/View/scrollPosition%28id%3Aanchor%3A%29), [scrollTargetLayout(isEnabled:)](https://developer.apple.com/documentation/swiftui/view/scrolltargetlayout%28isenabled%3A%29)
- Apple Developer Forums: [Scrolling through long lists with ScrollView and LazyVStack](https://developer.apple.com/forums/thread/806214)
- fatbobman.com: [The Evolution of SwiftUI Scroll Control APIs](https://fatbobman.com/en/posts/the-evolution-of-swiftui-scroll-control-apis/)
- Branch `experiment/flattened-row-scroll` contains all experiment code
