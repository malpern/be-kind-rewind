import AppKit
import TaggingKit

@MainActor
enum CollectionGridActionSupport {
    static func handleSaveToWatchLaterShortcut(
        selectedVideoIds: Set<String>,
        perform: () -> Void
    ) {
        guard !selectedVideoIds.isEmpty else {
            AppLogger.commands.debug("Ignored saveToWatchLater command: no selected videos")
            return
        }
        AppLogger.commands.info("Handling saveToWatchLater for \(selectedVideoIds.count, privacy: .public) videos")
        perform()
    }

    static func handleSaveToPlaylistShortcut(
        selectedVideoIds: Set<String>,
        perform: () -> Void
    ) {
        guard !selectedVideoIds.isEmpty else {
            AppLogger.commands.debug("Ignored saveToPlaylist command: no selected videos")
            return
        }
        AppLogger.commands.info("Handling saveToPlaylist for \(selectedVideoIds.count, privacy: .public) videos")
        perform()
    }

    static func handleMoveToPlaylistShortcut(
        selectedVideoIds: Set<String>,
        perform: () -> Void
    ) {
        guard !selectedVideoIds.isEmpty else {
            AppLogger.commands.debug("Ignored moveToPlaylist command: no selected videos")
            return
        }
        AppLogger.commands.info("Handling moveToPlaylist for \(selectedVideoIds.count, privacy: .public) videos")
        perform()
    }

    static func handleCandidateShortcut(
        commandName: StaticString,
        selectedVideoIds: Set<String>,
        selectedTopicId: Int64?,
        allCandidatesEligible: Bool,
        perform: () -> Void
    ) {
        guard selectedTopicId != nil,
              !selectedVideoIds.isEmpty,
              allCandidatesEligible else {
            AppLogger.commands.debug("Ignored \(commandName, privacy: .public) command: selection not eligible")
            return
        }
        AppLogger.commands.info("Handling \(commandName, privacy: .public) for \(selectedVideoIds.count, privacy: .public) videos")
        perform()
    }

    static func handleOpenSelectedShortcut(
        selectedVideoIds: Set<String>,
        perform: () -> Void
    ) {
        guard !selectedVideoIds.isEmpty else {
            AppLogger.commands.debug("Ignored openOnYouTube command: no selected videos")
            return
        }
        AppLogger.commands.info("Handling openOnYouTube for \(selectedVideoIds.count, privacy: .public) videos")
        perform()
    }

    static func clearSelection(
        collectionView: NSCollectionView?,
        selectedVideoIds: inout Set<String>,
        selectedVideoId: inout String?,
        renderedSelectedVideoIds: inout Set<String>,
        renderedSelectedVideoId: inout String?,
        isApplyingSelectionToCollectionView: inout Bool,
        onSelectionChange: (String?, Set<String>) -> Void,
        refreshVisibleItems: () -> Void
    ) {
        guard let collectionView else {
            AppLogger.commands.debug("Ignored clearSelection command: collection view unavailable")
            return
        }
        let selectionCount = selectedVideoIds.count
        AppLogger.commands.info("Handling clearSelection for \(selectionCount, privacy: .public) videos")
        selectedVideoId = nil
        selectedVideoIds = []
        renderedSelectedVideoId = nil
        renderedSelectedVideoIds = []
        isApplyingSelectionToCollectionView = true
        collectionView.deselectAll(nil)
        isApplyingSelectionToCollectionView = false
        onSelectionChange(nil, [])
        refreshVisibleItems()
    }

    static func excludeCreatorFromWatch(
        store: OrganizerStore?,
        sender: Any?
    ) {
        guard let store,
              let payload = (sender as? NSMenuItem)?.representedObject as? [String: String],
              let channelId = payload["channelId"], !channelId.isEmpty else {
            return
        }

        let channelName = payload["channelName"]
        let channelIconUrl = payload["channelIconUrl"]
        store.excludeCreatorFromWatch(
            channelId: channelId,
            channelName: channelName,
            channelIconUrl: channelIconUrl?.isEmpty == false ? channelIconUrl : nil
        )
    }

    static func saveToPlaylist(
        store: OrganizerStore?,
        sender: NSMenuItem,
        selectedVideoIds: Set<String>,
        allCandidatesEligible: Bool
    ) {
        guard let store,
              let playlist = sender.representedObject as? PlaylistRecord else { return }
        if let topicId = store.selectedTopicId, allCandidatesEligible {
            store.saveCandidatesToPlaylist(topicId: topicId, videoIds: Array(selectedVideoIds), playlist: playlist)
        } else {
            store.saveVideosToPlaylist(videoIds: Array(selectedVideoIds), playlist: playlist)
        }
    }

    static func moveToPlaylist(
        store: OrganizerStore?,
        sender: NSMenuItem,
        selectedVideoIds: Set<String>
    ) {
        guard let store,
              let destination = sender.representedObject as? PlaylistRecord,
              let sourcePlaylistId = store.selectedPlaylistId,
              sourcePlaylistId != destination.playlistId,
              let sourcePlaylist = store.knownPlaylists().first(where: { $0.playlistId == sourcePlaylistId }) else { return }

        store.saveVideosToPlaylist(videoIds: Array(selectedVideoIds), playlist: destination)
        store.removeVideosFromPlaylist(videoIds: Array(selectedVideoIds), playlist: sourcePlaylist)
    }

    static func removeFromPlaylist(
        store: OrganizerStore?,
        sender: NSMenuItem,
        selectedVideoIds: Set<String>
    ) {
        guard let store,
              let playlist = sender.representedObject as? PlaylistRecord else { return }
        store.removeVideosFromPlaylist(videoIds: Array(selectedVideoIds), playlist: playlist)
    }

    static func markNotInterested(
        store: OrganizerStore?,
        selectedVideoIds: Set<String>
    ) {
        guard let store, let topicId = store.selectedTopicId else { return }
        store.markCandidatesNotInterested(topicId: topicId, videoIds: Array(selectedVideoIds))
    }

    static func withFirstSelectedVideo(
        selectedVideoIds: Set<String>,
        perform: (String) -> Void
    ) {
        guard let videoId = selectedVideoIds.first else { return }
        perform(videoId)
    }

    static func showPlaylistPopup(
        mode: CollectionGridPlaylistShortcutMode,
        store: OrganizerStore?,
        collectionView: NSCollectionView?,
        selectedVideoIds: Set<String>,
        orderedIndexPaths: [IndexPath],
        frameForIndexPath: (IndexPath) -> CGRect?,
        target: AnyObject,
        saveSelector: Selector,
        moveSelector: Selector
    ) {
        guard let collectionView else { return }
        let videoIds = Array(selectedVideoIds)
        let selectionCount = videoIds.count
        let menu: NSMenu?
        switch mode {
        case .save:
            if let store {
                menu = CollectionGridPlaylistMenus.buildSaveMenu(
                    store: store,
                    selectedVideoIds: videoIds,
                    selectionCount: selectionCount,
                    target: target,
                    action: saveSelector
                )
            } else {
                menu = nil
            }
        case .move:
            if let store {
                menu = CollectionGridPlaylistMenus.buildMoveMenu(
                    store: store,
                    selectedVideoIds: videoIds,
                    target: target,
                    action: moveSelector
                )
            } else {
                menu = nil
            }
        }

        guard let menu, !menu.items.isEmpty else {
            NSSound.beep()
            return
        }

        let popupPoint: NSPoint
        if let indexPath = orderedIndexPaths.first,
           let frame = frameForIndexPath(indexPath) {
            popupPoint = NSPoint(x: frame.midX, y: frame.midY)
        } else {
            popupPoint = NSPoint(x: collectionView.visibleRect.midX, y: collectionView.visibleRect.midY)
        }

        menu.popUp(positioning: nil, at: popupPoint, in: collectionView)
    }
}
