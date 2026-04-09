import SwiftUI

/// SwiftUI content hosted inside each NSCollectionView cell, handling hover debounce and thumbnail display.
struct VideoCardWrapper: View {
    let video: VideoGridItemModel
    let isSelected: Bool
    let cacheDir: URL
    let displaySettings: DisplaySettings
    let store: OrganizerStore
    let onTap: () -> Void
    let onDoubleClick: () -> Void

    @State private var isHovering = false
    @State private var hoverOffTask: Task<Void, Never>?

    var body: some View {
        VideoGridItem(
            video: video,
            isSelected: isSelected,
            isHovering: isHovering,
            cacheDir: cacheDir,
            showMetadata: displaySettings.showMetadata,
            size: displaySettings.thumbnailSize,
            highlightTerms: store.parsedQuery.includeTerms,
            forceShowTitle: !store.parsedQuery.isEmpty
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onDoubleClick() }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded { onTap() }
        )
        .onHover { hovering in
            if hovering {
                hoverOffTask?.cancel()
                hoverOffTask = nil
                isHovering = true
                store.hoveredVideoId = video.id
            } else {
                hoverOffTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(GridConstants.hoverDebounceMs))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: GridConstants.hoverFadeOutDuration)) {
                        isHovering = false
                    }
                    if store.hoveredVideoId == video.id {
                        store.hoveredVideoId = nil
                    }
                }
            }
        }
        .cursor(.pointingHand)
    }
}
