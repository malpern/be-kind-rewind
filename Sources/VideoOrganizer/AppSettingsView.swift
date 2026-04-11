import AppKit
import SwiftUI
import TaggingKit
import UniformTypeIdentifiers

struct AppSettingsView: View {
    @Bindable var store: OrganizerStore
    @Bindable var displaySettings: DisplaySettings
    @Bindable var youTubeAuth: YouTubeAuthController

    @State private var selectedPane: AppSettingsPane = .general
    @State private var anthropicKeyInput = ""
    @State private var youTubeAPIKeyInput = ""
    @State private var credentialMessage: String?

    var body: some View {
        TabView(selection: $selectedPane) {
            AppSettingsGeneralPane(
                store: store,
                displaySettings: displaySettings
            )
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .tag(AppSettingsPane.general)

            AppSettingsAccountsPane(
                store: store,
                youTubeAuth: youTubeAuth,
                anthropicKeyInput: $anthropicKeyInput,
                youTubeAPIKeyInput: $youTubeAPIKeyInput,
                credentialMessage: $credentialMessage,
                saveAnthropicKey: saveAnthropicKey,
                saveYouTubeAPIKey: saveYouTubeAPIKey,
                importOAuthClientJSON: importOAuthClientJSON
            )
            .tabItem {
                Label("Accounts", systemImage: "person.crop.circle")
            }
            .tag(AppSettingsPane.accounts)

            AppSettingsWatchPane(
                store: store
            )
            .tabItem {
                Label("Watch", systemImage: "eye")
            }
            .tag(AppSettingsPane.watch)

            AppSettingsAdvancedPane(
                store: store
            )
            .tabItem {
                Label("Advanced", systemImage: "wrench.and.screwdriver")
            }
            .tag(AppSettingsPane.advanced)
        }
        .frame(width: 720, height: 640)
        .onAppear(perform: refreshAll)
    }

    private func refreshAll() {
        store.refreshSyncQueueSummary()
        store.refreshSeenHistoryCount()
        store.refreshExcludedCreators()
        store.refreshBrowserExecutorStatus()
        store.refreshCredentialBackedClients()
        store.refreshYouTubeQuotaSnapshot()
        youTubeAuth.refreshStatus(clearError: false)
    }

    private func saveAnthropicKey() {
        do {
            try ClaudeClient.storeAPIKey(anthropicKeyInput)
            anthropicKeyInput = ""
            store.refreshCredentialBackedClients()
            credentialMessage = "Saved Anthropic key to your macOS Keychain."
        } catch {
            credentialMessage = error.localizedDescription
        }
    }

    private func saveYouTubeAPIKey() {
        do {
            try YouTubeClient.storeAPIKey(youTubeAPIKeyInput)
            youTubeAPIKeyInput = ""
            store.refreshCredentialBackedClients()
            credentialMessage = "Saved YouTube Data API key to your macOS Keychain."
        } catch {
            credentialMessage = error.localizedDescription
        }
    }

    private func importOAuthClientJSON() {
        let panel = NSOpenPanel()
        panel.title = "Import Google OAuth Client JSON"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try YouTubeOAuthClientConfig.installDownloadedClientJSON(from: url)
            youTubeAuth.refreshStatus(clearError: true)
            credentialMessage = "Imported Google OAuth client JSON."
        } catch {
            credentialMessage = error.localizedDescription
        }
    }
}

private enum AppSettingsPane: Hashable {
    case general
    case accounts
    case watch
    case advanced
}
