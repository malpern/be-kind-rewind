import SwiftUI
import TaggingKit

struct AppSettingsGeneralPane: View {
    @Bindable var store: OrganizerStore
    @Bindable var displaySettings: DisplaySettings

    var body: some View {
        AppSettingsPaneContainer(
            title: "General",
            subtitle: "App-wide preferences and optional intelligence features."
        ) {
            AppSettingsSection(
                title: "Workspace",
                description: "Inline browsing controls stay in the sidebar, not in Settings."
            ) {
                Toggle("Keep inspector visible", isOn: $displaySettings.showInspector)
            }

            AppSettingsSection(
                title: "AI Assistance",
                description: "Claude-powered creator analysis."
            ) {
                Toggle(isOn: Bindable(store).claudeThemeClassificationEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Enable Claude theme classification")
                        Text("Classifies creator libraries into themed clusters and caches the results locally.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                AppSettingsMessageRow(
                    text: "Runs only when needed and caches results locally."
                )
            }
        }
    }
}

struct AppSettingsAccountsPane: View {
    @Bindable var store: OrganizerStore
    @Bindable var youTubeAuth: YouTubeAuthController
    @Binding var anthropicKeyInput: String
    @Binding var youTubeAPIKeyInput: String
    @Binding var credentialMessage: String?

    let saveAnthropicKey: () -> Void
    let saveYouTubeAPIKey: () -> Void
    let importOAuthClientJSON: () -> Void

    var body: some View {
        AppSettingsPaneContainer(
            title: "Accounts",
            subtitle: "Credentials and connected services."
        ) {
            AppSettingsSection(
                title: "API Keys",
                description: "Stored securely in Keychain."
            ) {
                apiKeyBlock(
                    title: "Anthropic",
                    isConfigured: ClaudeClient.hasStoredAPIKey(),
                    configuredMessage: "Anthropic key stored",
                    missingMessage: "Anthropic key missing",
                    detail: "Needed for AI topic discovery, creator themes, and suggestions.",
                    placeholder: "sk-ant-...",
                    text: $anthropicKeyInput,
                    saveTitle: "Save Anthropic Key",
                    saveAction: saveAnthropicKey,
                    clearAction: {
                        ClaudeClient.clearStoredAPIKey()
                        anthropicKeyInput = ""
                        store.refreshCredentialBackedClients()
                        credentialMessage = "Removed stored Anthropic key from Keychain."
                    }
                )

                Divider()

                apiKeyBlock(
                    title: "YouTube Data API",
                    isConfigured: YouTubeClient.hasStoredAPIKey(),
                    configuredMessage: "YouTube API key stored",
                    missingMessage: "YouTube API key missing",
                    detail: "Improves discovery refreshes, metadata fetches, and playlist verification.",
                    placeholder: "AIza...",
                    text: $youTubeAPIKeyInput,
                    saveTitle: "Save YouTube API Key",
                    saveAction: saveYouTubeAPIKey,
                    clearAction: {
                        YouTubeClient.clearStoredAPIKey()
                        youTubeAPIKeyInput = ""
                        store.refreshCredentialBackedClients()
                        credentialMessage = "Removed stored YouTube API key from Keychain."
                    }
                )

                if let credentialMessage {
                    Divider()
                    AppSettingsMessageRow(text: credentialMessage)
                }
            }

            AppSettingsSection(
                title: "YouTube Connection",
                description: "For playlist writes, private playlists, and browser-backed actions."
            ) {
                AppSettingsStatusRow(
                    title: "Account Access",
                    message: youTubeAuth.statusTitle,
                    detail: youTubeAuth.errorMessage ?? youTubeAuth.statusDetail,
                    icon: youTubeAuth.isConnected
                        ? (youTubeAuth.hasWriteAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        : "xmark.circle.fill",
                    tint: youTubeAuth.isConnected
                        ? (youTubeAuth.hasWriteAccess ? .green : .orange)
                        : .secondary
                )

                if youTubeAuth.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for browser authorization…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if youTubeAuth.isConnected {
                    AppSettingsButtonRow(buttons: [
                        AppSettingsButtonSpec("Reconnect") {
                            youTubeAuth.connect()
                        },
                        AppSettingsButtonSpec("Refresh Status") {
                            youTubeAuth.refreshStatus()
                        },
                        AppSettingsButtonSpec("Disconnect", role: .destructive) {
                            youTubeAuth.disconnect()
                        }
                    ])
                } else {
                    AppSettingsButtonRow(buttons: [
                        AppSettingsButtonSpec(
                            youTubeAuth.buttonTitle,
                            isDisabled: youTubeAuth.isBusy || !youTubeAuth.hasClientConfig
                        ) {
                            youTubeAuth.connect()
                        },
                        AppSettingsButtonSpec("Refresh Status") {
                            youTubeAuth.refreshStatus()
                        }
                    ])
                }

                Divider()

                Button("Import OAuth Client JSON…") {
                    importOAuthClientJSON()
                }

                if !youTubeAuth.hasClientConfig {
                    AppSettingsMessageRow(text: "No OAuth client JSON installed.")
                }
            }
        }
    }

    @ViewBuilder
    private func apiKeyBlock(
        title: String,
        isConfigured: Bool,
        configuredMessage: String,
        missingMessage: String,
        detail: String,
        placeholder: String,
        text: Binding<String>,
        saveTitle: String,
        saveAction: @escaping () -> Void,
        clearAction: @escaping () -> Void
    ) -> some View {
        AppSettingsStatusRow(
            title: title,
            message: isConfigured ? configuredMessage : missingMessage,
            detail: detail,
            icon: isConfigured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            tint: isConfigured ? .green : .orange
        )

        SecureField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)

        HStack(spacing: 12) {
            Button(saveTitle, action: saveAction)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Clear", role: .destructive, action: clearAction)
                .disabled(!isConfigured && text.wrappedValue.isEmpty)
        }
    }
}

struct AppSettingsWatchPane: View {
    @Bindable var store: OrganizerStore

    var body: some View {
        AppSettingsPaneContainer(
            title: "Watch",
            subtitle: "Discovery and filtering behavior."
        ) {
            AppSettingsSection(
                title: "Discovery",
                description: "Controls when the app may spend API quota."
            ) {
                Toggle(isOn: Bindable(store).apiSearchFallbackEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Allow YouTube API search fallback")
                        Text("Ask before spending `search.list` quota when scrape-based search fails.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Text("Per-refresh API budget")
                    Spacer()
                    Stepper(
                        value: Bindable(store).apiFallbackPassBudgetUnits,
                        in: 100...10_000,
                        step: 100
                    ) {
                        Text("\(store.apiFallbackPassBudgetUnits) units")
                            .font(.body.monospacedDigit())
                            .frame(minWidth: 110, alignment: .trailing)
                    }
                }

                AppSettingsMessageRow(
                    text: "Calls that would exceed the budget are skipped automatically."
                )
            }

            AppSettingsSection(
                title: "History",
                description: "Imported history lets Watch hide videos you have already seen."
            ) {
                AppSettingsStatusRow(
                    title: "Watch History",
                    message: store.seenHistoryCount > 0
                        ? "Already-watched suppression is on"
                        : "Already-watched suppression is off",
                    detail: store.seenHistoryCount > 0
                        ? "Imported \(store.seenHistoryCount) watch history event\(store.seenHistoryCount == 1 ? "" : "s")."
                        : "Watch still works without history import; this is only for suppressing repeats.",
                    icon: store.seenHistoryCount > 0 ? "checkmark.circle.fill" : "info.circle.fill",
                    tint: store.seenHistoryCount > 0 ? .green : .secondary
                )

                AppSettingsMetricRow(
                    label: "Imported seen events",
                    value: "\(store.seenHistoryCount)"
                )

                HStack(spacing: 12) {
                    Button("Import Watch History…") {
                        store.importSeenHistoryFromPanel()
                    }

                    Button("Refresh Count") {
                        store.refreshSeenHistoryCount()
                    }
                }
            }

            AppSettingsSection(
                title: "Excluded Creators",
                description: "Creators excluded from Watch are kept out of future discovery until you restore them."
            ) {
                if store.excludedCreators.isEmpty {
                    AppSettingsMessageRow(
                        text: "No creators are currently excluded. Use “Exclude Creator from Watch” from a video or inspector to manage this list."
                    )
                } else {
                    ForEach(store.excludedCreators) { creator in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(creator.channelName)
                                    .font(.body.weight(.semibold))
                                Text(creator.channelId)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Restore") {
                                store.restoreExcludedCreator(channelId: creator.channelId)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AppSettingsAdvancedPane: View {
    @Bindable var store: OrganizerStore

    var body: some View {
        let summary = store.syncQueueSummary

        AppSettingsPaneContainer(
            title: "Advanced",
            subtitle: "Operational status and recovery tools."
        ) {
            AppSettingsSection(
                title: "YouTube Quota",
                description: "Estimated daily usage against the standard quota."
            ) {
                if let snapshot = store.youtubeQuotaSnapshot {
                    AppSettingsStatusRow(
                        title: "Daily Usage",
                        message: "\(snapshot.usedUnitsToday) used, \(snapshot.remainingUnitsToday) remaining",
                        detail: "Resets at \(resetTimeString(snapshot.resetAt)) Pacific.",
                        icon: snapshot.remainingUnitsToday > 0
                            ? "gauge.with.dots.needle.50percent"
                            : "exclamationmark.triangle.fill",
                        tint: snapshot.remainingUnitsToday > 0 ? .secondary : .orange
                    )

                    AppSettingsMetricRow(label: "Used today", value: "\(snapshot.usedUnitsToday)")
                    AppSettingsMetricRow(label: "Remaining", value: "\(snapshot.remainingUnitsToday)")

                    if !snapshot.recentAPIEvents.isEmpty {
                        Text("Recent API Usage")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(snapshot.recentAPIEvents.prefix(6)) { event in
                            AppSettingsEventRow(
                                title: event.operation.label,
                                detail: event.detail,
                                trailing: "\(event.estimatedUnits)u",
                                success: event.success
                            )
                        }
                    }

                    if !snapshot.recentDiscoveryEvents.isEmpty {
                        Text("Recent Discovery Telemetry")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(snapshot.recentDiscoveryEvents.prefix(8)) { event in
                            AppSettingsEventRow(
                                title: "\(event.backend.rawValue.capitalized) \(event.kind.rawValue)",
                                detail: event.detail,
                                trailing: event.outcome.rawValue,
                                success: event.outcome != .failed
                            )
                        }
                    }
                } else {
                    AppSettingsMessageRow(text: "Loading quota estimates…")
                }

                AppSettingsButtonRow(buttons: [
                    AppSettingsButtonSpec("Refresh Quota Telemetry") {
                        store.refreshYouTubeQuotaSnapshot()
                    }
                ])
            }

            AppSettingsSection(
                title: "Sync & Browser Fallback",
                description: "Queue status, browser login, and recovery."
            ) {
                AppSettingsStatusRow(
                    title: "Browser Fallback",
                    message: store.browserExecutorReady ? "Browser fallback ready" : "Browser fallback needs attention",
                    detail: store.browserExecutorStatusMessage,
                    icon: store.browserExecutorReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: store.browserExecutorReady ? .green : .orange
                )

                AppSettingsMetricRow(label: "Queued", value: "\(summary.queued)")
                AppSettingsMetricRow(label: "Retrying", value: "\(summary.retrying)")
                AppSettingsMetricRow(label: "Deferred", value: "\(summary.deferred)")
                AppSettingsMetricRow(label: "In Progress", value: "\(summary.inProgress)")

                if summary.browserDeferred > 0 {
                    AppSettingsMessageRow(
                        text: "\(summary.browserDeferred) browser actions are waiting for the Playwright executor profile."
                    )
                }

                AppSettingsButtonRow(buttons: [
                    AppSettingsButtonSpec("Refresh Status") {
                        store.refreshSyncQueueSummary()
                        store.refreshBrowserExecutorStatus()
                    },
                    AppSettingsButtonSpec("Flush Now") {
                        store.processPendingSync(reason: "settings")
                        store.processPendingBrowserSync(reason: "settings")
                    },
                    AppSettingsButtonSpec("Open Browser Sign-In") {
                        store.openBrowserSyncLogin()
                    }
                ])

                if let lastSyncErrorMessage = store.lastSyncErrorMessage {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last Sync Error")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(lastSyncErrorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if store.lastSyncErrorIsBrowser {
                            Button("Open Artifacts Folder") {
                                store.openBrowserSyncArtifactsFolder()
                            }
                        }
                    }
                }
            }
        }
    }

    private func resetTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return formatter.string(from: date)
    }
}
