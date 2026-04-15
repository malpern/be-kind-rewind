import Foundation

@MainActor
final class CollectionGridCommandObservers {
    private var tokens: [NSObjectProtocol] = []

    func install(
        saveToWatchLater: @escaping @MainActor () -> Void,
        saveToPlaylist: @escaping @MainActor () -> Void,
        moveToPlaylist: @escaping @MainActor () -> Void,
        dismissCandidates: @escaping @MainActor () -> Void,
        notInterested: @escaping @MainActor () -> Void,
        openOnYouTube: @escaping @MainActor () -> Void,
        clearSelection: @escaping @MainActor () -> Void,
        toggleShowDismissed: @escaping @MainActor () -> Void
    ) {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: AppCommandBridge.saveToWatchLater, object: nil, queue: .main) { _ in
                Task { @MainActor in saveToWatchLater() }
            },
            center.addObserver(forName: AppCommandBridge.saveToPlaylist, object: nil, queue: .main) { _ in
                Task { @MainActor in saveToPlaylist() }
            },
            center.addObserver(forName: AppCommandBridge.moveToPlaylist, object: nil, queue: .main) { _ in
                Task { @MainActor in moveToPlaylist() }
            },
            center.addObserver(forName: AppCommandBridge.dismissCandidates, object: nil, queue: .main) { _ in
                Task { @MainActor in dismissCandidates() }
            },
            center.addObserver(forName: AppCommandBridge.notInterested, object: nil, queue: .main) { _ in
                Task { @MainActor in notInterested() }
            },
            center.addObserver(forName: AppCommandBridge.openOnYouTube, object: nil, queue: .main) { _ in
                Task { @MainActor in openOnYouTube() }
            },
            center.addObserver(forName: AppCommandBridge.clearSelection, object: nil, queue: .main) { _ in
                Task { @MainActor in clearSelection() }
            },
            center.addObserver(forName: AppCommandBridge.toggleShowDismissed, object: nil, queue: .main) { _ in
                Task { @MainActor in toggleShowDismissed() }
            }
        ]
    }

    func removeAll() {
        guard !tokens.isEmpty else { return }
        let center = NotificationCenter.default
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }
}
