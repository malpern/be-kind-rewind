import AppKit
import Foundation
import TaggingKit

extension OrganizerStore {
    func processPendingSync(reason: String = "manual") {
        guard syncTask == nil else {
            AppLogger.sync.debug("Skipping sync request for \(reason, privacy: .public); a sync task is already running")
            return
        }

        recoverInterruptedSyncActions(context: reason)

        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }

            do {
                refreshSyncQueueSummary()
                let pendingActions = try store.pendingSyncPlan(executor: .api)
                guard !pendingActions.isEmpty else {
                    AppLogger.sync.debug("No pending sync actions for \(reason, privacy: .public)")
                    return
                }

                AppLogger.sync.info("Syncing \(pendingActions.count, privacy: .public) pending YouTube actions for \(reason, privacy: .public)")
                try store.markInProgress(ids: pendingActions.map(\.id))
                let client = try YouTubeClient()
                let result = await YouTubeSyncService(client: client).execute(actions: pendingActions)
                try store.markSynced(ids: result.syncedActionIDs)
                try store.markDeferred(ids: result.deferredActionIDs, error: "Waiting for browser executor")
                try store.moveToExecutor(
                    ids: result.browserFallbackActionIDs,
                    executor: .browser,
                    state: .deferred,
                    error: "API quota exhausted. Waiting for browser executor fallback."
                )
                let retryDelay = SyncCoordinator.retryDelay(for: result.failures)
                try store.markFailed(result.failures, retryAfter: retryDelay)

                if let firstFailure = result.failures.first {
                    AppLogger.sync.error("YouTube sync failure: \(firstFailure.message, privacy: .public)")
                    alert = AppAlertState(title: "Could Not Save to YouTube", message: firstFailure.message)
                    lastSyncErrorMessage = firstFailure.message
                    lastSyncErrorIsBrowser = false
                }

                if !result.browserFallbackActionIDs.isEmpty {
                    AppLogger.sync.info("Moved \(result.browserFallbackActionIDs.count, privacy: .public) actions to browser fallback after API quota exhaustion")
                    alert = AppAlertState(
                        title: "Using Browser Fallback",
                        message: "YouTube API quota is exhausted, so queued save actions have been moved to the browser executor path. They will stay queued until the Playwright worker is attached."
                    )
                    processPendingBrowserSync(reason: "quota-fallback")
                }

                refreshSyncQueueSummary()
            } catch {
                AppLogger.sync.error("Pending sync run failed: \(error.localizedDescription, privacy: .public)")
                alert = AppAlertState(title: "Could Not Save to YouTube", message: error.localizedDescription)
                lastSyncErrorMessage = error.localizedDescription
                lastSyncErrorIsBrowser = false
                refreshSyncQueueSummary()
            }
        }
    }

    func processPendingBrowserSync(reason: String = "manual") {
        guard browserSyncTask == nil else {
            AppLogger.sync.debug("Skipping browser sync request for \(reason, privacy: .public); a browser sync task is already running")
            return
        }

        recoverInterruptedSyncActions(context: reason)

        browserSyncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.browserSyncTask = nil }

            do {
                refreshSyncQueueSummary()
                let pendingActions = try store.pendingSyncPlan(executor: .browser)
                guard !pendingActions.isEmpty else {
                    AppLogger.sync.debug("No pending browser sync actions for \(reason, privacy: .public)")
                    return
                }

                AppLogger.sync.info("Syncing \(pendingActions.count, privacy: .public) pending browser actions for \(reason, privacy: .public)")
                try store.markInProgress(ids: pendingActions.map(\.id))
                let result = try await BrowserSyncService(environment: runtimeEnvironment).execute(actions: pendingActions)
                try store.markSynced(ids: result.syncedActionIDs)
                let retryDelay = SyncCoordinator.retryDelay(for: result.failures)
                try store.markFailed(result.failures, retryAfter: retryDelay)

                if let firstFailure = result.failures.first {
                    AppLogger.sync.error("Browser sync failure: \(firstFailure.message, privacy: .public)")
                    alert = AppAlertState(title: "Could Not Sync Browser Actions", message: firstFailure.message)
                    lastSyncErrorMessage = firstFailure.message
                    lastSyncErrorIsBrowser = true
                }

                refreshSyncQueueSummary()
            } catch {
                AppLogger.sync.error("Pending browser sync run failed: \(error.localizedDescription, privacy: .public)")
                alert = AppAlertState(title: "Could Not Sync Browser Actions", message: error.localizedDescription)
                lastSyncErrorMessage = error.localizedDescription
                lastSyncErrorIsBrowser = true
                refreshSyncQueueSummary()
            }
        }
    }

    func openBrowserSyncLogin() {
        Task {
            do {
                try await BrowserSyncService(environment: runtimeEnvironment).openLoginSetup()
                SyncCoordinator.bringBrowserSyncWindowToFront()
                browserExecutorReady = false
                browserExecutorStatusMessage = "Browser sign-in window opened. Sign in to YouTube there if needed, then return here and click Refresh sync status."
                alert = AppAlertState(
                    title: "Browser Sign-In Opened",
                    message: "A dedicated Chrome profile window was opened for browser fallback actions. Sign in to YouTube there if needed, then refresh sync status here."
                )
            } catch {
                alert = AppAlertState(title: "Could Not Open Browser Sign-In", message: error.localizedDescription)
            }
        }
    }

    func refreshSyncQueueSummary() {
        do {
            syncQueueSummary = try store.syncQueueSummary()
        } catch {
            AppLogger.sync.error("Failed to refresh sync queue summary: \(error.localizedDescription, privacy: .public)")
            syncQueueSummary = SyncQueueSummary(queued: 0, retrying: 0, deferred: 0, inProgress: 0, browserDeferred: 0)
        }
    }

    func refreshBrowserExecutorStatus() {
        browserStatusTask?.cancel()
        browserExecutorStatusMessage = "Checking browser executor status…"
        let environment = runtimeEnvironment
        browserStatusTask = Task.detached(priority: .userInitiated) {
            let resolvedStatus: BrowserExecutorStatus
            do {
                resolvedStatus = try await withThrowingTaskGroup(of: BrowserExecutorStatus.self) { group in
                    group.addTask {
                        try await BrowserSyncService(environment: environment).status()
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        return BrowserExecutorStatus(
                            ready: false,
                            message: "Browser status check timed out. If the sign-in window is open, finish there and then refresh sync status."
                        )
                    }

                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                }
            } catch {
                resolvedStatus = BrowserExecutorStatus(ready: false, message: error.localizedDescription)
            }

            if Task.isCancelled { return }
            await MainActor.run {
                self.browserExecutorReady = resolvedStatus.ready
                self.browserExecutorStatusMessage = resolvedStatus.message
                self.browserStatusTask = nil
            }
        }
    }

    func openBrowserSyncArtifactsFolder() {
        NSWorkspace.shared.open(runtimeEnvironment.browserSyncArtifactsDirectory())
    }

    func startSyncLoop() {
        guard syncLoopTask == nil else { return }
        syncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await MainActor.run {
                    self.processPendingSync(reason: "timer")
                    self.processPendingBrowserSync(reason: "timer")
                }
            }
        }
    }

    func recoverInterruptedSyncActions(context: String) {
        do {
            let recovered = try store.recoverStaleInProgressCommits()
            guard recovered > 0 else { return }
            AppLogger.sync.info("Recovered \(recovered, privacy: .public) interrupted sync actions before \(context, privacy: .public)")
            refreshSyncQueueSummary()
        } catch {
            AppLogger.sync.error("Failed to recover interrupted sync actions before \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum SyncCoordinator {
    static func retryDelay(for failures: [SyncFailureRecord]) -> TimeInterval? {
        guard let first = failures.first else { return nil }
        let message = first.message.lowercased()
        if message.contains("quota") || message.contains("daily limit") || message.contains("exceeded") {
            return 60 * 60
        }
        if message.contains("write access is not available") || message.contains("reconnect youtube") {
            return 15 * 60
        }
        return 5 * 60
    }

    @MainActor
    static func bringBrowserSyncWindowToFront() {
        if let runningChrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
            runningChrome.activate(options: [.activateAllWindows])
            return
        }

        if let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: chromeURL, configuration: configuration)
        }
    }
}
