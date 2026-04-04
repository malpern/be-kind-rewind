import Foundation

enum AppCommandBridge {
    static let saveToWatchLater = Notification.Name("videoOrganizer.saveToWatchLater")
    static let saveToPlaylist = Notification.Name("videoOrganizer.saveToPlaylist")
    static let moveToPlaylist = Notification.Name("videoOrganizer.moveToPlaylist")
    static let dismissCandidates = Notification.Name("videoOrganizer.dismissCandidates")
    static let notInterested = Notification.Name("videoOrganizer.notInterested")
    static let openOnYouTube = Notification.Name("videoOrganizer.openOnYouTube")
    static let clearSelection = Notification.Name("videoOrganizer.clearSelection")
    static let saveToFavoritePlaylist = Notification.Name("videoOrganizer.saveToFavoritePlaylist")

    static func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }
}
