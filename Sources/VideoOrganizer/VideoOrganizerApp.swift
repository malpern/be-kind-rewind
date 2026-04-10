import SwiftUI
import TaggingKit

@main
struct VideoOrganizerApp: App {
    @AppStorage("hasSeenCredentialOnboarding") private var hasSeenCredentialOnboarding = false
    @State private var store: OrganizerStore?
    @State private var thumbnailCache = ThumbnailCache()
    @State private var displaySettings = DisplaySettings()
    @State private var youTubeAuth = YouTubeAuthController()
    @State private var loadError: String?
    @State private var showCredentialOnboarding = false

    var body: some Scene {
        Window("Be Kind, Rewind", id: "main") {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    InlineLoadingView()
                }
            }
            .task {
                if store == nil && loadError == nil {
                    await initializeStore()
                }
            }
            .sheet(isPresented: $displaySettings.showQuickNavigator) {
                if let store {
                    QuickNavigatorView(
                        store: store,
                        displaySettings: displaySettings,
                        isPresented: $displaySettings.showQuickNavigator
                    )
                }
            }
            .sheet(isPresented: $showCredentialOnboarding) {
                FirstRunCredentialOnboardingView {
                    hasSeenCredentialOnboarding = true
                    showCredentialOnboarding = false
                }
            }
        }
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
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
        if store?.selectedChannelId != nil {
            store?.clearChannelFilter()
            displaySettings.toast.show("Creator Filter Cleared", icon: "person.crop.circle.badge.xmark")
        }
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

    private func initializeStore() async {
        let logFileURL = AppLogger.file.logFileURL
        AppLogger.app.info("Initializing app store")
        AppLogger.file.log("App initializing, log file: \(logFileURL.path)", category: "app")
        do {
            let client = try? ClaudeClient()
            let dbPath = resolveDbPath()
            let newStore = try OrganizerStore(dbPath: dbPath, claudeClient: client)
            store = newStore
            evaluateCredentialOnboardingEligibility()
            AppLogger.app.info("App store initialized")
        } catch {
            loadError = error.localizedDescription
            AppLogger.app.error("Failed to initialize app store: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveDbPath() -> String {
        let environment = RuntimeEnvironment()
        let legacyCandidates = [
            URL(fileURLWithPath: "/tmp/full-tagger-v2.db"),
            environment.currentDirectoryURL.appendingPathComponent("video-tagger.db")
        ]
        return environment.preferredDatabaseURL(legacyCandidates: legacyCandidates).path
    }

    private func evaluateCredentialOnboardingEligibility() {
        guard !hasSeenCredentialOnboarding else { return }

        let hasAnthropicKey = ClaudeClient.hasStoredAPIKey()
        let hasYouTubeAPIKey = YouTubeClient.hasStoredAPIKey()
        let hasYouTubeOAuthConfig = YouTubeOAuthClientConfig.isAvailable()
        showCredentialOnboarding = !(hasAnthropicKey && hasYouTubeAPIKey && hasYouTubeOAuthConfig)
    }
}

private struct FirstRunCredentialOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let complete: () -> Void

    private let hasAnthropicKey = ClaudeClient.hasStoredAPIKey()
    private let hasYouTubeAPIKey = YouTubeClient.hasStoredAPIKey()
    private let hasYouTubeOAuthConfig = YouTubeOAuthClientConfig.isAvailable()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Finish Setup")
                    .font(.largeTitle.weight(.semibold))

                Text("Be Kind, Rewind can store your API keys securely in Keychain. You can finish setup from Settings without touching Terminal.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                onboardingRow(
                    title: "Anthropic API key",
                    detail: hasAnthropicKey
                        ? "Available"
                        : "Needed for AI topic discovery and suggestions.",
                    isReady: hasAnthropicKey
                )

                onboardingRow(
                    title: "YouTube Data API key",
                    detail: hasYouTubeAPIKey
                        ? "Available"
                        : "Needed for candidate refreshes, metadata, and playlist verification.",
                    isReady: hasYouTubeAPIKey
                )

                onboardingRow(
                    title: "Google OAuth client JSON",
                    detail: hasYouTubeOAuthConfig
                        ? "Available"
                        : "Import the downloaded desktop OAuth client JSON to enable playlist saves and private-playlist access.",
                    isReady: hasYouTubeOAuthConfig
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Text("Open Settings to paste keys or import the Google OAuth client JSON. You can skip this for now and come back later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Continue for Now") {
                    complete()
                    dismiss()
                }

                Spacer()

                Button("Open Settings") {
                    complete()
                    AppLogger.app.info("Opening settings from credential onboarding")
                    openSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    @ViewBuilder
    private func onboardingRow(title: String, detail: String, isReady: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(isReady ? .green : .orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}

private struct AppMenuCommands: Commands {
    @Bindable var displaySettings: DisplaySettings
    let store: OrganizerStore?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Be Kind, Rewind") {
                AppLogger.app.info("Opening About window")
                openWindow(id: "about")
            }
        }

        CommandGroup(after: .textEditing) {
            Button("Find...") {
                AppLogger.commands.info("Requesting sidebar search focus")
                displaySettings.searchRequested = true
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(after: .appSettings) {
            Button("Open Quickly…") {
                AppLogger.commands.info("Opening quick navigator")
                displaySettings.showQuickNavigator = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(store == nil)
        }

        CommandMenu("View") {
            Picker("Page Mode", selection: Binding(
                get: { store?.pageDisplayMode ?? .saved },
                set: { newMode in
                    Task { @MainActor in
                        await store?.activatePageDisplayMode(newMode)
                    }
                }
            )) {
                ForEach(TopicDisplayMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.symbolName)
                        .tag(mode)
                }
            }

            if store?.pageDisplayMode == .watchCandidates {
                Picker("Watch Layout", selection: Binding(
                    get: { store?.watchPresentationMode ?? .byTopic },
                    set: { store?.setWatchPresentationMode($0) }
                )) {
                    ForEach(WatchPresentationMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.symbolName)
                            .tag(mode)
                    }
                }
            }

            Divider()

            Button {
                displaySettings.showInspector.toggle()
                AppLogger.commands.info("Toggled inspector from menu: \(displaySettings.showInspector, privacy: .public)")
            } label: {
                Label("Toggle Inspector", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: .command)

            Divider()

            Button {
                AppLogger.commands.info("Requesting sidebar focus")
                displaySettings.focusSidebarRequested = true
            } label: {
                Label("Focus Topics", systemImage: "sidebar.leading")
            }
            .keyboardShortcut("[", modifiers: .command)

            Button {
                AppLogger.commands.info("Requesting grid focus")
                displaySettings.focusGridRequested = true
            } label: {
                Label("Focus Videos", systemImage: "square.grid.3x3")
            }
            .keyboardShortcut("]", modifiers: .command)

            Divider()

            Button {
                toggleSort(.views)
            } label: {
                Label("Sort by Views", systemImage: SortOrder.views.sfSymbol)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button {
                toggleSort(.date)
            } label: {
                Label("Sort by Date", systemImage: SortOrder.date.sfSymbol)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button {
                toggleSort(.duration)
            } label: {
                Label("Sort by Length", systemImage: SortOrder.duration.sfSymbol)
            }
            .keyboardShortcut("3", modifiers: .command)

            Button {
                toggleSort(.creator)
            } label: {
                Label("Sort by Creator", systemImage: SortOrder.creator.sfSymbol)
            }
            .keyboardShortcut("4", modifiers: .command)

            Button {
                toggleSort(.alphabetical)
            } label: {
                Label("Sort A-Z", systemImage: SortOrder.alphabetical.sfSymbol)
            }
            .keyboardShortcut("5", modifiers: .command)

            Button {
                toggleSort(.shuffle)
            } label: {
                Label("Shuffle", systemImage: SortOrder.shuffle.sfSymbol)
            }
            .keyboardShortcut("6", modifiers: .command)

            Divider()

            Button {
                displaySettings.sortOrder = nil
            } label: {
                Label("Clear Sort", systemImage: "line.3.horizontal.decrease.circle")
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(displaySettings.sortOrder == nil)

            Divider()

            Button {
                displaySettings.showMetadata.toggle()
            } label: {
                Label("Compressed Layout", systemImage: "rectangle.compress.vertical")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandMenu("Actions") {
            Button("Save to Watch Later") {
                AppCommandBridge.post(AppCommandBridge.saveToWatchLater)
            }
            .keyboardShortcut("l", modifiers: [])

            Button("Save to Playlist…") {
                AppCommandBridge.post(AppCommandBridge.saveToPlaylist)
            }
            .keyboardShortcut("p", modifiers: [])

            Button("Move to Playlist…") {
                AppCommandBridge.post(AppCommandBridge.moveToPlaylist)
            }
            .keyboardShortcut("p", modifiers: [.shift])

            Divider()

            Button("Dismiss") {
                AppCommandBridge.post(AppCommandBridge.dismissCandidates)
            }
            .keyboardShortcut("d", modifiers: [])

            Button("Not Interested") {
                AppCommandBridge.post(AppCommandBridge.notInterested)
            }
            .keyboardShortcut("n", modifiers: [])

            Divider()

            Button("Open on YouTube") {
                AppCommandBridge.post(AppCommandBridge.openOnYouTube)
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("Clear Selection") {
                AppCommandBridge.post(AppCommandBridge.clearSelection)
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private func toggleSort(_ order: SortOrder) {
        if store?.selectedChannelId != nil {
            store?.clearChannelFilter()
            displaySettings.toast.show("Creator Filter Cleared", icon: "person.crop.circle.badge.xmark")
        }
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
