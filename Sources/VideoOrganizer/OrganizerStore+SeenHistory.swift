import AppKit
import TaggingKit
import UniformTypeIdentifiers

extension OrganizerStore {
    func importSeenHistoryFromPanel() {
        SeenHistoryController.importSeenHistory(from: self)
    }

    func refreshSeenHistoryCount() {
        do {
            seenHistoryCount = try store.seenVideoCount()
        } catch {
            AppLogger.app.error("Failed to refresh seen history count: \(error.localizedDescription, privacy: .public)")
            seenHistoryCount = 0
        }
    }
}

private enum SeenHistoryController {
    @MainActor
    static func importSeenHistory(from store: OrganizerStore) {
        let panel = NSOpenPanel()
        panel.title = "Import Watch History"
        panel.message = "Choose a Google Takeout or My Activity export file."
        panel.allowedContentTypes = [.json, .html, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let records = try SeenHistoryImporter.loadRecords(from: url)
            let imported = try store.store.importSeenVideoRecords(records)
            store.refreshSeenHistoryCount()
            store.candidateRefreshToken += 1
            AppLogger.discovery.info("Imported \(imported, privacy: .public) seen-history records from \(url.lastPathComponent, privacy: .public)")
            store.alert = AppAlertState(
                title: "Watch History Imported",
                message: "Parsed \(records.count) history records and imported \(imported) new entries from \(url.lastPathComponent)."
            )
        } catch {
            AppLogger.discovery.error("Failed to import seen history from \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            store.alert = AppAlertState(
                title: "Could Not Import Watch History",
                message: error.localizedDescription
            )
        }
    }
}
