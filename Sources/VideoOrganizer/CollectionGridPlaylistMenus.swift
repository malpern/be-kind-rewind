import AppKit
import TaggingKit

@MainActor
enum CollectionGridPlaylistShortcutMode {
    case save
    case move
}

@MainActor
enum CollectionGridPlaylistMenus {
    static func buildSaveMenu(
        store: OrganizerStore,
        selectedVideoIds: [String],
        selectionCount: Int,
        target: AnyObject,
        action: Selector
    ) -> NSMenu {
        let menu = NSMenu(title: "Save to Playlist")

        for (index, playlist) in store.knownPlaylists().enumerated() {
            let item = NSMenuItem(title: playlist.title, action: action, keyEquivalent: "")
            if index < 9 {
                item.title = "\(index + 1). \(playlist.title)"
            }
            item.representedObject = playlist
            item.target = target

            let membershipCount = selectedVideoIds.reduce(into: 0) { count, videoId in
                if store.playlistsForVideo(videoId).contains(where: { $0.playlistId == playlist.playlistId }) {
                    count += 1
                }
            }

            if membershipCount == selectionCount {
                item.state = .on
                item.isEnabled = false
            } else if membershipCount > 0 {
                item.state = .mixed
                item.isEnabled = true
            } else {
                item.state = .off
                item.isEnabled = true
            }

            menu.addItem(item)
        }

        return menu
    }

    static func buildMoveMenu(
        store: OrganizerStore,
        selectedVideoIds: [String],
        target: AnyObject,
        action: Selector
    ) -> NSMenu? {
        guard !selectedVideoIds.isEmpty,
              let sourcePlaylistId = store.selectedPlaylistId else { return nil }

        let menu = NSMenu(title: "Move to Playlist")
        for playlist in store.knownPlaylists().filter({ $0.playlistId != sourcePlaylistId }) {
            let item = NSMenuItem(title: playlist.title, action: action, keyEquivalent: "")
            item.representedObject = playlist
            item.target = target
            menu.addItem(item)
        }
        return menu
    }

    static func removablePlaylists(
        store: OrganizerStore,
        selectedVideoIds: [String]
    ) -> [PlaylistRecord] {
        let removablePlaylistIds = Set(
            selectedVideoIds.flatMap { store.playlistsForVideo($0).map(\.playlistId) }
        )
        return store.knownPlaylists().filter { removablePlaylistIds.contains($0.playlistId) }
    }
}
