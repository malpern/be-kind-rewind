import AppKit
import SwiftUI
import TaggingKit
import UniformTypeIdentifiers

struct AppSettingsView: View {
    @Bindable var store: OrganizerStore
    @Bindable var displaySettings: DisplaySettings
    @Bindable var youTubeAuth: YouTubeAuthController
    @State private var anthropicKeyInput = ""
    @State private var youTubeAPIKeyInput = ""
    @State private var credentialMessage: String?

    var body: some View {
        let summary = store.syncQueueSummary

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("API Keys")
                        .font(.title3.weight(.semibold))

                    authStatusCard(
                        title: "Anthropic",
                        message: ClaudeClient.hasStoredAPIKey() ? "Anthropic key stored" : "Anthropic key missing",
                        detail: ClaudeClient.hasStoredAPIKey()
                            ? "Stored securely in Keychain or available from your existing config."
                            : "Paste your Anthropic API key here. It will be stored securely in your macOS Keychain.",
                        icon: ClaudeClient.hasStoredAPIKey() ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: ClaudeClient.hasStoredAPIKey() ? .green : .orange
                    )

                    SecureField("sk-ant-...", text: $anthropicKeyInput)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        Button("Save Anthropic Key") {
                            saveAnthropicKey()
                        }
                        .disabled(anthropicKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Clear") {
                            ClaudeClient.clearStoredAPIKey()
                            anthropicKeyInput = ""
                            store.refreshCredentialBackedClients()
                            credentialMessage = "Removed stored Anthropic key from Keychain."
                        }
                    }

                    authStatusCard(
                        title: "YouTube Data API",
                        message: YouTubeClient.hasStoredAPIKey() ? "YouTube API key stored" : "YouTube API key missing",
                        detail: YouTubeClient.hasStoredAPIKey()
                            ? "Stored securely in Keychain or available from your existing config."
                            : "Paste your YouTube Data API key here to improve discovery refreshes and playlist verification.",
                        icon: YouTubeClient.hasStoredAPIKey() ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: YouTubeClient.hasStoredAPIKey() ? .green : .orange
                    )

                    SecureField("AIza...", text: $youTubeAPIKeyInput)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        Button("Save YouTube API Key") {
                            saveYouTubeAPIKey()
                        }
                        .disabled(youTubeAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Clear") {
                            YouTubeClient.clearStoredAPIKey()
                            youTubeAPIKeyInput = ""
                            store.refreshCredentialBackedClients()
                            credentialMessage = "Removed stored YouTube API key from Keychain."
                        }
                    }

                    if let credentialMessage {
                        Text(credentialMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("YouTube")
                        .font(.title3.weight(.semibold))

                    authStatusCard(
                        title: "API access",
                        message: youTubeAuth.statusTitle,
                        detail: youTubeAuth.errorMessage ?? youTubeAuth.statusDetail,
                        icon: youTubeAuth.isConnected ? (youTubeAuth.hasWriteAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") : "xmark.circle.fill",
                        tint: youTubeAuth.isConnected ? (youTubeAuth.hasWriteAccess ? .green : .orange) : .secondary
                    )

                    if youTubeAuth.isConnected {
                        HStack(spacing: 12) {
                            if youTubeAuth.isBusy {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Waiting for browser authorization…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Button("Reconnect") {
                                    youTubeAuth.connect()
                                }

                                Button("Refresh status") {
                                    youTubeAuth.refreshStatus()
                                }
                            }

                            Button("Disconnect") {
                                youTubeAuth.disconnect()
                            }
                        }
                        Button("Import OAuth Client JSON…") {
                            importOAuthClientJSON()
                        }
                    } else {
                        Text(youTubeAuth.statusTitle)
                            .font(.subheadline.weight(.semibold))

                        Text(youTubeAuth.errorMessage ?? youTubeAuth.statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            youTubeAuth.connect()
                        } label: {
                            HStack(spacing: 12) {
                                YouTubeLogoMarkView()
                                    .frame(width: 34, height: 24)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(youTubeAuth.buttonTitle)
                                        .font(.headline)
                                        .foregroundStyle(Color.black.opacity(0.92))

                                    Text(youTubeAuth.buttonSubtitle)
                                        .font(.caption)
                                        .foregroundStyle(Color.black.opacity(0.62))
                                        .multilineTextAlignment(.leading)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(youTubeAuth.isBusy || !youTubeAuth.hasClientConfig)

                        if youTubeAuth.isBusy {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Waiting for browser authorization…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack(spacing: 12) {
                                Button("Refresh status") {
                                    youTubeAuth.refreshStatus()
                                }

                                Button("Import OAuth Client JSON…") {
                                    importOAuthClientJSON()
                                }
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("History (Optional)")
                        .font(.title3.weight(.semibold))

                    authStatusCard(
                        title: "Watch history",
                        message: store.seenHistoryCount > 0 ? "Already-watched suppression is on" : "Already-watched suppression is off",
                        detail: store.seenHistoryCount > 0
                            ? "Imported \(store.seenHistoryCount) watch history event\(store.seenHistoryCount == 1 ? "" : "s"). Watch recommendations can now filter out videos you've already seen."
                            : "Watch recommendations still work without this. Importing Google Takeout or My Activity history simply helps hide videos you've already watched.",
                        icon: store.seenHistoryCount > 0 ? "checkmark.circle.fill" : "info.circle.fill",
                        tint: store.seenHistoryCount > 0 ? .green : .secondary
                    )

                    HStack {
                        Text("Imported seen events")
                            .font(.subheadline)
                        Spacer()
                        Text("\(store.seenHistoryCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text("Import a Google Takeout or My Activity export if you want Watch recommendations to suppress videos you've already seen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button("Import Watch History…") {
                            store.importSeenHistoryFromPanel()
                        }

                        Button("Refresh count") {
                            store.refreshSeenHistoryCount()
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Sync")
                        .font(.title3.weight(.semibold))

                    authStatusCard(
                        title: "Browser fallback",
                        message: store.browserExecutorReady ? "Browser fallback ready" : "Browser fallback needs attention",
                        detail: store.browserExecutorStatusMessage,
                        icon: store.browserExecutorReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: store.browserExecutorReady ? .green : .orange
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        syncRow("Queued", value: summary.queued)
                        syncRow("Retrying", value: summary.retrying)
                        syncRow("Deferred", value: summary.deferred)
                        syncRow("In Progress", value: summary.inProgress)

                        if summary.browserDeferred > 0 {
                            Text("\(summary.browserDeferred) browser actions are waiting for the Playwright executor profile.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Refresh sync status") {
                            store.refreshSyncQueueSummary()
                            store.refreshBrowserExecutorStatus()
                        }

                        Button("Flush now") {
                            store.processPendingSync(reason: "settings")
                            store.processPendingBrowserSync(reason: "settings")
                        }
                    }

                    if let lastSyncErrorMessage = store.lastSyncErrorMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Last sync error")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(lastSyncErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if store.lastSyncErrorIsBrowser {
                                Button("Open artifacts folder") {
                                    store.openBrowserSyncArtifactsFolder()
                                }
                            }
                        }
                    }

                    Button {
                        store.openBrowserSyncLogin()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "globe.badge.chevron.backward")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 1) {
                                Text("Open Browser Sign-In")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("Use the persistent Playwright profile for browser fallback actions like Not Interested.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.quaternary, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 760)
        .onAppear {
            store.refreshSyncQueueSummary()
            store.refreshSeenHistoryCount()
            store.refreshBrowserExecutorStatus()
            store.refreshCredentialBackedClients()
        }
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
            credentialMessage = "Saved YouTube API key to your macOS Keychain."
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

    private func syncRow(_ label: String, value: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text("\(value)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func authStatusCard(
        title: String,
        message: String,
        detail: String,
        icon: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(message)
                    .font(.subheadline.weight(.semibold))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }
}
