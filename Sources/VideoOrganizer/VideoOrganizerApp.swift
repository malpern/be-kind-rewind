import SwiftUI
import TaggingKit

@main
struct VideoOrganizerApp: App {
    @State private var store: OrganizerStore?
    @State private var thumbnailCache = ThumbnailCache()
    @State private var displaySettings = DisplaySettings()
    @State private var youTubeAuth = YouTubeAuthController()
    @State private var loadError: String?
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    OrganizerView(
                        store: store,
                        thumbnailCache: thumbnailCache,
                        displaySettings: displaySettings
                    )
                } else if let loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Database Error")
                            .font(.title2)
                        Text(loadError)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Color.clear
                }
            }
            .task {
                await initializeStore()
            }
            .onAppear {
                showSplashWindow()
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            AppMenuCommands(displaySettings: displaySettings, store: store)
        }
        Window("About Be Kind, Rewind", id: "about") {
            AboutView()
        }
        .defaultSize(width: 980, height: 1280)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        Settings {
            if let store {
                AppSettingsView(
                    store: store,
                    displaySettings: displaySettings,
                    youTubeAuth: youTubeAuth
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))
                    Text("The app is still loading its database.")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 420, height: 220)
                .padding(20)
            }
        }
    }

    private func toggleSort(_ order: SortOrder) {
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
    }

    private func showSplashWindow() {
        let splashWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        splashWindow.isOpaque = false
        splashWindow.backgroundColor = .clear
        splashWindow.hasShadow = true
        splashWindow.level = .floating
        splashWindow.center()
        splashWindow.contentView = NSHostingView(rootView: SplashView())
        splashWindow.makeKeyAndOrderFront(nil)

        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.4
                    splashWindow.animator().alphaValue = 0
                }, completionHandler: {
                    Task { @MainActor in
                        splashWindow.orderOut(nil)
                    }
                })
            }
        }
    }

    private func initializeStore() async {
        do {
            let client = try? ClaudeClient()
            let dbPath = resolveDbPath()
            let newStore = try OrganizerStore(dbPath: dbPath, claudeClient: client)
            store = newStore

            let allVideoIds = newStore.topics.flatMap { topic in
                newStore.videosForTopic(topic.id).compactMap { $0.videoId.isEmpty ? nil : $0.videoId }
            }
            await thumbnailCache.prefetch(videoIds: allVideoIds)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func resolveDbPath() -> String {
        let candidates = [
            "/tmp/full-tagger-v2.db",
            FileManager.default.currentDirectoryPath + "/video-tagger.db"
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return candidates.last!
    }
}

private struct AppMenuCommands: Commands {
    @Bindable var displaySettings: DisplaySettings
    let store: OrganizerStore?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Be Kind, Rewind") {
                openWindow(id: "about")
            }
        }

        CommandGroup(after: .textEditing) {
            Button("Find...") {
                displaySettings.searchRequested = true
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(after: .appSettings) {
            Button("Save to Watch Later") {
                NotificationCenter.default.post(name: .videoOrganizerSaveToWatchLater, object: nil)
            }
            .keyboardShortcut("w", modifiers: [])

            Button("Save to Playlist…") {
                NotificationCenter.default.post(name: .videoOrganizerSaveToPlaylist, object: nil)
            }
            .keyboardShortcut("p", modifiers: [])

            Button("Move to Playlist…") {
                NotificationCenter.default.post(name: .videoOrganizerMoveToPlaylist, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.shift])

            Button("Dismiss") {
                NotificationCenter.default.post(name: .videoOrganizerDismissCandidates, object: nil)
            }
            .keyboardShortcut("d", modifiers: [])

            Button("Not Interested") {
                NotificationCenter.default.post(name: .videoOrganizerNotInterested, object: nil)
            }
            .keyboardShortcut("n", modifiers: [])

            Divider()

            Button("Open on YouTube") {
                NotificationCenter.default.post(name: .videoOrganizerOpenOnYouTube, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("Clear Selection") {
                NotificationCenter.default.post(name: .videoOrganizerClearSelection, object: nil)
            }
            .keyboardShortcut(.escape, modifiers: [])
        }

        CommandMenu("Favorites") {
            if let store {
                ForEach(Array(store.knownPlaylists().prefix(9).enumerated()), id: \.element.id) { index, playlist in
                    Button("\(index + 1). \(playlist.title)") {
                        NotificationCenter.default.post(
                            name: .videoOrganizerSaveToFavoritePlaylist,
                            object: nil,
                            userInfo: ["index": index]
                        )
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                }
            } else {
                Button("No Favorite Playlists Available") {}
                    .disabled(true)
            }
        }

        CommandMenu("View") {
            Button("Toggle Inspector") {
                displaySettings.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)

            Divider()

            Button("Focus Topics") {
                displaySettings.focusSidebarRequested = true
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Focus Videos") {
                displaySettings.focusGridRequested = true
            }
            .keyboardShortcut("]", modifiers: .command)

            Divider()

            Button("Sort by Views") {
                toggleSort(.views)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Sort by Date") {
                toggleSort(.date)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Sort by Length") {
                toggleSort(.duration)
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("Sort by Creator") {
                toggleSort(.creator)
            }
            .keyboardShortcut("4", modifiers: .command)

            Button("Sort A-Z") {
                toggleSort(.alphabetical)
            }
            .keyboardShortcut("5", modifiers: .command)

            Button("Shuffle") {
                toggleSort(.shuffle)
            }
            .keyboardShortcut("6", modifiers: .command)

            Divider()

            Button("Clear Sort") {
                displaySettings.sortOrder = nil
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(displaySettings.sortOrder == nil)

            Divider()

            Button("Compressed Layout") {
                displaySettings.showMetadata.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandMenu("Actions") {
            Button("Save to Watch Later") {
                NotificationCenter.default.post(name: .videoOrganizerSaveToWatchLater, object: nil)
            }
            .keyboardShortcut("w", modifiers: [])

            Button("Save to Playlist…") {
                NotificationCenter.default.post(name: .videoOrganizerSaveToPlaylist, object: nil)
            }
            .keyboardShortcut("p", modifiers: [])

            Button("Move to Playlist…") {
                NotificationCenter.default.post(name: .videoOrganizerMoveToPlaylist, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.shift])

            Divider()

            Button("Dismiss") {
                NotificationCenter.default.post(name: .videoOrganizerDismissCandidates, object: nil)
            }
            .keyboardShortcut("d", modifiers: [])

            Button("Not Interested") {
                NotificationCenter.default.post(name: .videoOrganizerNotInterested, object: nil)
            }
            .keyboardShortcut("n", modifiers: [])

            Divider()

            Button("Open on YouTube") {
                NotificationCenter.default.post(name: .videoOrganizerOpenOnYouTube, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("Clear Selection") {
                NotificationCenter.default.post(name: .videoOrganizerClearSelection, object: nil)
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private func toggleSort(_ order: SortOrder) {
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
    }
}
