# NSCollectionView Grid Implementation Plan

## What You're Building

Replace the center grid pane in the Be Kind, Rewind video organizer with an `NSCollectionView` wrapped in `NSViewRepresentable`. The sidebar and inspector stay in SwiftUI. Only the grid changes.

**The problem this solves:** Clicking a topic in the left sidebar should scroll the center grid to that section. SwiftUI's `LazyVStack` can't do this reliably for far-away sections (see `docs/adr-001-nscollectionview-grid.md` for the full evidence).

## Current Architecture

```
NavigationSplitView {
    TopicSidebar (SwiftUI)          ← stays as-is
} detail: {
    AllVideosGridView (SwiftUI)     ← REPLACE THIS
        .inspector {
            VideoInspector (SwiftUI) ← stays as-is
        }
}
```

**OrganizerView.swift:13** is where the grid is wired in. Replace `AllVideosGridView(...)` with your new `NSCollectionView`-backed view, matching the same init signature: `(store:thumbnailCache:displaySettings:)`.

## Data Flow

All data comes from three `@Observable` objects. Your view receives them as parameters:

- **`OrganizerStore`** — topics, videos, selection state, search, channel filtering
  - `store.topics: [TopicViewModel]` — ordered list of ~22 topics with subtopics
  - `store.videosForTopic(id) -> [VideoViewModel]` — videos for a topic
  - `store.selectedTopicId: Int64?` — which topic is selected in sidebar
  - `store.selectedVideoId: String?` — which video is selected in grid
  - `store.searchText: String` — current search query
  - `store.selectedChannelId: String?` — channel filter (from creator circles)
  - `store.selectedSubtopicId: Int64?` — subtopic filter

- **`DisplaySettings`** — UI preferences
  - `displaySettings.thumbnailSize: Double` — 120-400, default 220
  - `displaySettings.showMetadata: Bool` — toggle card metadata display
  - `displaySettings.scrollToTopicRequested: Int64?` — set by sidebar, your view consumes this
  - `displaySettings.sortOrder: SortOrder?` — current sort (views, date, duration, creator, alphabetical, shuffle)
  - `displaySettings.sortAscending: Bool`
  - `displaySettings.focusGridRequested: Bool` — keyboard focus request

- **`ThumbnailCache`** — manages thumbnail images
  - `thumbnailCache.cacheDirURL: URL` — local cache directory for thumbnail files

## What the Grid Must Do

### Core
1. Display videos in a grid with N columns (based on container width and thumbnail size)
2. Group videos into sections by topic, with pinned section headers
3. **Scroll to a topic section when `displaySettings.scrollToTopicRequested` is set** — this is the whole reason for the rewrite
4. Support video selection (click to select, highlight selected video)
5. Sync selection back to `store.selectedVideoId`

### Section Headers
Each section header shows:
- Topic icon + name + video count (see `SectionHeaderView.swift`)
- Optionally a `CreatorCirclesBar` row of channel avatars (see `CreatorCirclesBar.swift`)
- Headers should pin/stick at the top while scrolling through that section

### Video Cards
Each card shows:
- Thumbnail image (16:9 aspect ratio, loaded from cache directory)
- Duration badge overlay
- When `showMetadata` is true: channel icon, title (2 lines), channel name, view count + date
- Selection highlight border
- Hover state
- Context menu (Move to... other topics)
- Double-click opens YouTube

The existing `VideoGridItem.swift` and `VideoCardWrapper.swift` have the SwiftUI implementations. You can either:
- Rewrite the cell in AppKit (more work, better performance)
- Wrap the existing SwiftUI `VideoGridItem` in `NSHostingView` per cell (faster to implement, some overhead)

### Reactivity
The grid must update when these change:
- `store.topics` / search / filters → reload sections and items
- `displaySettings.thumbnailSize` → resize cells, recompute columns
- `displaySettings.showMetadata` → toggle metadata visibility, resize cells
- `displaySettings.sortOrder` / `sortAscending` → re-sort within sections
- `store.selectedChannelId` → filter videos to one channel
- `store.selectedSubtopicId` → filter videos to one subtopic

### Keyboard Navigation
- Arrow keys / hjkl: move selection through the grid
- Home/End: jump to first/last video
- Page Up/Down: jump by several rows

## Scroll Navigation Contract

This is the critical behavior:

```swift
// Sidebar sets this:
displaySettings.scrollToTopicRequested = topicId

// Your view observes it and scrolls:
// 1. Read the value
// 2. Clear it (set to nil)
// 3. Scroll the collection view to that section
// 4. Select the first video in that section
// 5. Set store.selectedVideoId
```

With `NSCollectionView`, this is straightforward:
```swift
let indexPath = IndexPath(item: 0, section: sectionIndex)
collectionView.scrollToItems(at: [indexPath], scrollPosition: .top)
```

## Key Files to Read

| File | What it does |
|------|-------------|
| `OrganizerView.swift` | Where the grid is wired in (line 13) |
| `AllVideosGridView.swift` | Current SwiftUI grid — your reference for behavior |
| `VideoGridItem.swift` | Video card rendering |
| `VideoCardWrapper.swift` | Card wrapper with hover/click handling |
| `SectionHeaderView.swift` | Section header UI |
| `CreatorCirclesBar.swift` | Channel avatar row in headers |
| `GridConstants.swift` | All layout constants (spacing, padding, font sizes) |
| `TopicSidebar.swift` | How sidebar triggers scroll (sets `scrollToTopicRequested`) |
| `OrganizerStore.swift` | Data layer — topics, videos, selection |
| `DisplaySettings.swift` | UI state — thumbnail size, sort, scroll requests |
| `TopicSection` model (in AllVideosGridView.swift:686) | Section data model |
| `VideoGridItemModel` (in AllVideosGridView.swift:705) | Video item model |

## Implementation Strategy

### Phase 1: Basic grid with scroll
- `NSViewRepresentable` wrapping `NSCollectionView`
- Compositional layout with N columns based on width
- Simple cells (thumbnail + title, no metadata yet)
- Section headers (topic name + count)
- `scrollToItems(at:scrollPosition:)` when `scrollToTopicRequested` fires
- Wire into `OrganizerView` replacing `AllVideosGridView`
- **Test:** Click sidebar topics, verify grid scrolls correctly

### Phase 2: Full card rendering
- Full video card cells matching current design (metadata, hover, selection, duration badge)
- Channel icon in metadata
- Selection highlighting and `store.selectedVideoId` sync
- Context menu (Move to...)
- Double-click to open YouTube

### Phase 3: Reactivity
- Respond to search/filter/sort changes with collection view updates
- Thumbnail size slider updates cell size
- Metadata toggle
- Channel and subtopic filtering
- Keyboard navigation

### Phase 4: Polish
- CreatorCirclesBar in section headers
- Section progress bar (optional — was in the SwiftUI version)
- Smooth animations for filter/sort transitions
- Performance profiling with 5,000 items

## Testing

Use Peekaboo CLI for automated testing:
```bash
# Build and launch
bash build-app.sh && open "Video Organizer.app"

# Find sidebar topic elements
peekaboo see --app "Be Kind, Rewind: Video Organizer" --json 2>&1 | python3 -c "
import json, sys
data = json.load(sys.stdin)
for e in data['data']['ui_elements']:
    ident = str(e.get('identifier',''))
    if ident.startswith('topic-') and e.get('role') == 'other':
        print(f'{e[\"id\"]} {ident} {e.get(\"label\",\"\")[:40]}')
"

# Click a topic and screenshot
peekaboo click --app "Be Kind, Rewind: Video Organizer" --on <element_id>
sleep 2
peekaboo image --mode screen --path /tmp/test.png
```

**Success criteria:** Clicking any sidebar topic (especially far-apart ones like Mechanical Keyboards → Home Automation → Embedded Systems) always lands on the correct section header. No crashes. Tested at least 5 far-apart topics repeatedly.

## What NOT to Do

- Don't modify the sidebar, inspector, or app state layer
- Don't change the data models (`TopicSection`, `VideoGridItemModel`) — use them as-is
- Don't try to fix scrolling in SwiftUI — that path is exhausted (see ADR-001)
- Don't use `NSScrollView` hacking around a SwiftUI `ScrollView` — that crashes
- Don't over-optimize diffing in Phase 1 — get behavior correct first, then optimize
