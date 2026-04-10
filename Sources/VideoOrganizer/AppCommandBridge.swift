import Foundation

/// Notification names used to forward menu-bar commands into the active SwiftUI view hierarchy.
enum AppCommandBridge {
    static let saveToWatchLater = Notification.Name("videoOrganizer.saveToWatchLater")
    static let saveToPlaylist = Notification.Name("videoOrganizer.saveToPlaylist")
    static let moveToPlaylist = Notification.Name("videoOrganizer.moveToPlaylist")
    static let dismissCandidates = Notification.Name("videoOrganizer.dismissCandidates")
    static let notInterested = Notification.Name("videoOrganizer.notInterested")
    static let openOnYouTube = Notification.Name("videoOrganizer.openOnYouTube")
    static let clearSelection = Notification.Name("videoOrganizer.clearSelection")

    static func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        AppLogger.commands.info("Dispatching command: \(commandName(for: name), privacy: .public)")
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    private static func commandName(for name: Notification.Name) -> String {
        switch name {
        case saveToWatchLater:
            return "saveToWatchLater"
        case saveToPlaylist:
            return "saveToPlaylist"
        case moveToPlaylist:
            return "moveToPlaylist"
        case dismissCandidates:
            return "dismissCandidates"
        case notInterested:
            return "notInterested"
        case openOnYouTube:
            return "openOnYouTube"
        case clearSelection:
            return "clearSelection"
        default:
            return name.rawValue
        }
    }
}
