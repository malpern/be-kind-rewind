import Foundation
import OSLog

/// Dual-output logger: writes to both os_log (for Console.app) and a rolling
/// file log (for reliable debugging when os_log filtering drops messages).
enum AppLogger {
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let app = Logger(subsystem: subsystem, category: "app")

    private static let subsystem = "com.malpern.video-organizer"

    /// File-based debug log that always works regardless of os_log filtering.
    /// Writes to ~/Library/Logs/VideoOrganizer/debug.log
    static let file = FileLogger()
}

/// Simple append-only file logger for debugging.
final class FileLogger: Sendable {
    let logFileURL: URL

    init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoOrganizer", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logFileURL = logsDir.appendingPathComponent("debug.log")

        // Rotate if over 2 MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? Int, size > 2_000_000 {
            let oldURL = logsDir.appendingPathComponent("debug.old.log")
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.moveItem(at: logFileURL, to: oldURL)
        }
    }

    func log(_ message: String, category: String = "app") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }
}
