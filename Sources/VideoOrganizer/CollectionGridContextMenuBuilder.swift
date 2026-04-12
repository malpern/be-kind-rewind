import AppKit
import TaggingKit

@MainActor
enum CollectionGridContextMenuBuilder {
    static func build(
        store: OrganizerStore?,
        selectedItems: [VideoGridItemModel],
        allCandidates: Bool,
        allSaved: Bool,
        target: AnyObject,
        openAction: Selector,
        copyAction: Selector,
        saveToWatchLaterAction: Selector,
        saveToPlaylistAction: Selector,
        moveToPlaylistAction: Selector,
        removeFromPlaylistAction: Selector,
        downloadVideoAction: Selector,
        cancelDownloadAction: Selector,
        playOfflineAction: Selector,
        deleteDownloadAction: Selector,
        dismissCandidatesAction: Selector,
        notInterestedAction: Selector,
        excludeCreatorAction: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        let selectionCount = selectedItems.count
        let selectedVideoIds = selectedItems.map(\.id)
        let selectedCreatorKeys = Set(selectedItems.compactMap { video -> String? in
            guard let channelId = video.channelId, !channelId.isEmpty else { return nil }
            return channelId
        })
        let singleSelectedCreator = selectedCreatorKeys.count == 1
            ? selectedItems.first(where: { $0.channelId == selectedCreatorKeys.first })
            : nil

        let openTitle = selectionCount == 1 ? "Open on YouTube" : "Open \(selectionCount) on YouTube"
        let openItem = NSMenuItem(title: openTitle, action: openAction, keyEquivalent: "\r")
        openItem.target = target
        menu.addItem(openItem)

        let copyTitle = selectionCount == 1 ? "Copy Link" : "Copy \(selectionCount) Links"
        let copyItem = NSMenuItem(title: copyTitle, action: copyAction, keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        copyItem.target = target
        menu.addItem(copyItem)

        guard let store else {
            menu.items.forEach { $0.target = target }
            return menu
        }

        menu.addItem(.separator())

        let saveToWatchLater = NSMenuItem(title: "Save to Watch Later", action: saveToWatchLaterAction, keyEquivalent: "")
        saveToWatchLater.target = target
        saveToWatchLater.keyEquivalent = "l"
        let watchLaterMembershipCount = selectedVideoIds.reduce(into: 0) { count, videoId in
            if store.playlistsForVideo(videoId).contains(where: { $0.playlistId == "WL" }) {
                count += 1
            }
        }
        if watchLaterMembershipCount == selectionCount {
            saveToWatchLater.state = .on
            saveToWatchLater.isEnabled = false
        } else if watchLaterMembershipCount > 0 {
            saveToWatchLater.state = .mixed
            saveToWatchLater.isEnabled = true
        } else {
            saveToWatchLater.state = .off
            saveToWatchLater.isEnabled = true
        }
        menu.addItem(saveToWatchLater)

        let playlistsMenu = CollectionGridPlaylistMenus.buildSaveMenu(
            store: store,
            selectedVideoIds: selectedVideoIds,
            selectionCount: selectionCount,
            target: target,
            action: saveToPlaylistAction
        )
        let saveToPlaylist = NSMenuItem(title: "Save to Playlist", action: nil, keyEquivalent: "")
        saveToPlaylist.submenu = playlistsMenu
        saveToPlaylist.keyEquivalent = "p"
        saveToPlaylist.isEnabled = !store.knownPlaylists().isEmpty
        menu.addItem(saveToPlaylist)

        if allSaved {
            if let moveMenu = CollectionGridPlaylistMenus.buildMoveMenu(
                store: store,
                selectedVideoIds: selectedVideoIds,
                target: target,
                action: moveToPlaylistAction
            ), !moveMenu.items.isEmpty {
                let moveItem = NSMenuItem(title: "Move to Playlist", action: nil, keyEquivalent: "")
                moveItem.submenu = moveMenu
                moveItem.keyEquivalent = "p"
                moveItem.keyEquivalentModifierMask = [.shift]
                menu.addItem(moveItem)
            }

            let removablePlaylists = CollectionGridPlaylistMenus.removablePlaylists(
                store: store,
                selectedVideoIds: selectedVideoIds
            )
            switch removablePlaylists.count {
            case 0:
                break
            case 1:
                let playlist = removablePlaylists[0]
                let removeItem = NSMenuItem(
                    title: "Remove from \(playlist.title)",
                    action: removeFromPlaylistAction,
                    keyEquivalent: ""
                )
                removeItem.representedObject = playlist
                removeItem.target = target
                menu.addItem(removeItem)
            default:
                let removeMenu = NSMenu(title: "Remove from Playlist")
                for playlist in removablePlaylists {
                    let item = NSMenuItem(title: playlist.title, action: removeFromPlaylistAction, keyEquivalent: "")
                    item.representedObject = playlist
                    item.target = target
                    let membershipCount = selectedVideoIds.reduce(into: 0) { count, videoId in
                        if store.playlistsForVideo(videoId).contains(where: { $0.playlistId == playlist.playlistId }) {
                            count += 1
                        }
                    }
                    if membershipCount == selectionCount {
                        item.state = .on
                    } else if membershipCount > 0 {
                        item.state = .mixed
                    } else {
                        item.state = .off
                    }
                    removeMenu.addItem(item)
                }
                let removeItem = NSMenuItem(title: "Remove from Playlist", action: nil, keyEquivalent: "")
                removeItem.submenu = removeMenu
                removeItem.isEnabled = !removeMenu.items.isEmpty
                menu.addItem(removeItem)
            }
        }

        if selectionCount == 1, let videoId = selectedVideoIds.first {
            menu.addItem(.separator())
            let downloadManager = VideoDownloadManager.shared
            if downloadManager.isDownloaded(videoId) {
                let play = NSMenuItem(title: "Play Offline", action: playOfflineAction, keyEquivalent: "")
                play.target = target
                menu.addItem(play)

                let delete = NSMenuItem(title: "Delete Download", action: deleteDownloadAction, keyEquivalent: "")
                delete.target = target
                menu.addItem(delete)
            } else if downloadManager.isActive(videoId) {
                let cancel = NSMenuItem(title: "Cancel Download", action: cancelDownloadAction, keyEquivalent: "")
                cancel.target = target
                menu.addItem(cancel)
            } else {
                let download = NSMenuItem(title: "Download for Offline", action: downloadVideoAction, keyEquivalent: "")
                download.target = target
                menu.addItem(download)
            }
        }

        if allCandidates, store.selectedTopicId != nil {
            menu.addItem(.separator())

            let dismiss = NSMenuItem(title: "Dismiss", action: dismissCandidatesAction, keyEquivalent: "d")
            dismiss.target = target
            menu.addItem(dismiss)

            let notInterested = NSMenuItem(title: "Not Interested", action: notInterestedAction, keyEquivalent: "n")
            notInterested.target = target
            menu.addItem(notInterested)

            if let creator = singleSelectedCreator,
               let channelId = creator.channelId,
               !channelId.isEmpty {
                let excludeCreator = NSMenuItem(
                    title: "Exclude Creator from Watch",
                    action: excludeCreatorAction,
                    keyEquivalent: ""
                )
                excludeCreator.representedObject = [
                    "channelId": channelId,
                    "channelName": creator.channelName ?? "",
                    "channelIconUrl": creator.channelIconUrl?.absoluteString ?? ""
                ]
                excludeCreator.target = target
                menu.addItem(excludeCreator)
            }
        }

        menu.items.forEach { $0.target = target }
        menu.autoenablesItems = false
        return menu
    }
}
