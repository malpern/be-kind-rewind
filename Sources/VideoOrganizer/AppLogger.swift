import OSLog

enum AppLogger {
    static let auth = Logger(subsystem: "com.malpern.video-organizer", category: "auth")
    static let discovery = Logger(subsystem: "com.malpern.video-organizer", category: "discovery")
    static let app = Logger(subsystem: "com.malpern.video-organizer", category: "app")
}
