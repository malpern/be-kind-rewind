import SwiftUI

struct OrganizerView: View {
    @Bindable var store: OrganizerStore
    let thumbnailCache: ThumbnailCache
    @Bindable var displaySettings: DisplaySettings

    var body: some View {
        NavigationSplitView {
            TopicSidebar(store: store, displaySettings: displaySettings)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            AllVideosGridView(store: store, thumbnailCache: thumbnailCache, displaySettings: displaySettings)
                .inspector(isPresented: $displaySettings.showInspector) {
                    VideoInspector(store: store, thumbnailCache: thumbnailCache)
                        .inspectorColumnWidth(min: 280, ideal: 300, max: 340)
                }
                .toolbar {
                    ToolbarItemGroup {
                        if store.isLoading {
                            ProgressView().controlSize(.small)
                        }

                        if thumbnailCache.isDownloading {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("\(thumbnailCache.downloadedCount)/\(thumbnailCache.totalCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            displaySettings.showInspector.toggle()
                        } label: {
                            Image(systemName: "sidebar.trailing")
                        }
                        .help(displaySettings.showInspector ? "Hide Inspector" : "Show Inspector")
                    }
                }
        }
    }
}
