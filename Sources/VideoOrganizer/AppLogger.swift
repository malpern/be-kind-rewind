import OSLog

enum AppLogger {
    static let auth = Logger(subsystem: "com.malpern.video-organizer", category: "auth")
    static let discovery = Logger(subsystem: "com.malpern.video-organizer", category: "discovery")
    static let sync = Logger(subsystem: "com.malpern.video-organizer", category: "sync")
    static let app = Logger(subsystem: "com.malpern.video-organizer", category: "app")
}
