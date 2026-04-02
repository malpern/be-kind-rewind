import SwiftUI
import TaggingKit

@main
struct VideoOrganizerApp: App {
    @State private var store: OrganizerStore?
    @State private var thumbnailCache = ThumbnailCache()
    @State private var displaySettings = DisplaySettings()
    @State private var loadError: String?
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    OrganizerView(store: store, thumbnailCache: thumbnailCache, displaySettings: displaySettings)
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
        Window("About Be Kind, Rewind", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
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
                    splashWindow.orderOut(nil)
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
