import SwiftUI

struct AppSettingsView: View {
    @Bindable var store: OrganizerStore
    @Bindable var displaySettings: DisplaySettings
    @Bindable var youTubeAuth: YouTubeAuthController

    var body: some View {
        let summary = store.syncQueueSummary

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("YouTube")
                        .font(.title3.weight(.semibold))

                    if youTubeAuth.isConnected {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.title3)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(youTubeAuth.statusTitle)
                                    .font(.subheadline.weight(.semibold))

                                Text(youTubeAuth.errorMessage ?? youTubeAuth.statusDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()
                        }

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
                            Button("Refresh status") {
                                youTubeAuth.refreshStatus()
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("History")
                        .font(.title3.weight(.semibold))

                    HStack {
                        Text("Imported seen events")
                            .font(.subheadline)
                        Spacer()
                        Text("\(store.seenHistoryCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text("Import a Google Takeout or My Activity export to suppress already-watched videos from watch candidates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button("Import Seen History…") {
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
        .frame(width: 500, height: 560)
        .onAppear {
            store.refreshSyncQueueSummary()
            store.refreshSeenHistoryCount()
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
}

