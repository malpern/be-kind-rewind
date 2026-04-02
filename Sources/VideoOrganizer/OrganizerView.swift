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
            CollectionGridView(store: store, thumbnailCache: thumbnailCache, displaySettings: displaySettings)
                .navigationTitle("")
                .inspector(isPresented: $displaySettings.showInspector) {
                    VideoInspector(store: store, thumbnailCache: thumbnailCache)
                        .inspectorColumnWidth(min: 280, ideal: 300, max: 340)
                        .accessibilityIdentifier("videoInspector")
                }
                .toolbar {
                    ToolbarItemGroup(placement: .automatic) {
                        sortButtons
                    }

                    ToolbarItemGroup(placement: .automatic) {
                        statusIndicators
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            displaySettings.showInspector.toggle()
                            displaySettings.toast.show(
                                displaySettings.showInspector ? "Inspector" : "Inspector Hidden",
                                icon: "sidebar.trailing"
                            )
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help(displaySettings.showInspector ? "Hide Inspector" : "Show Inspector")
                        .accessibilityIdentifier("toggleInspector")
                        .accessibilityLabel(displaySettings.showInspector ? "Hide inspector panel" : "Show inspector panel")
                    }
                }
        }
        .overlay(alignment: .top) {
            ActionToast(state: displaySettings.toast)
                .padding(.top, 4)
        }
        .accessibilityIdentifier("mainWindow")
    }

    @ViewBuilder
    private var sortButtons: some View {
        ForEach(SortOrder.allCases, id: \.self) { order in
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    if displaySettings.sortOrder == order {
                        if order == .shuffle {
                            displaySettings.sortAscending.toggle()
                        } else {
                            displaySettings.sortOrder = nil
                        }
                    } else {
                        displaySettings.sortOrder = order
                        displaySettings.sortAscending = false
                    }
                }
                displaySettings.toast.show(order.helpText, icon: order.sfSymbol)
            } label: {
                Label(order.label, systemImage: order.sfSymbol)
            }
            .foregroundStyle(displaySettings.sortOrder == order ? Color.accentColor : .secondary)
            .help(order.helpText)
            .accessibilityIdentifier("sort\(order.label)")
            .accessibilityLabel(order.accessibilityLabel)
            .accessibilityValue(displaySettings.sortOrder == order ? "Active" : "Inactive")
        }
    }

    @ViewBuilder
    private var statusIndicators: some View {
        if store.isLoading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading")
        }

        if thumbnailCache.isDownloading {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("\(thumbnailCache.downloadedCount)/\(thumbnailCache.totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Downloading thumbnails: \(thumbnailCache.downloadedCount) of \(thumbnailCache.totalCount)")
        }
    }
}
