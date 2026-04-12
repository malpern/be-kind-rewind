import AppKit
import Foundation

/// Manages offline video downloads via yt-dlp. Videos are stored in
/// `~/Library/Caches/VideoOrganizer/downloads/{videoId}.mp4`.
///
/// Downloads run as background `Process` tasks. Uses 720p max with
/// `--concurrent-fragments 4` for fast parallel downloads on a good
/// connection. Resume support (`-c`) so interrupted downloads continue
/// where they left off.
@MainActor
@Observable
final class VideoDownloadManager {
    static let shared = VideoDownloadManager()

    enum Status: Equatable {
        case idle
        case downloading(progress: Double)
        case completed(path: String)
        case failed(message: String)
    }

    /// Per-video download status keyed by videoId.
    private(set) var statuses: [String: Status] = [:]
    private var processes: [String: Process] = [:]

    private let downloadDir: URL
    private let manifestPath: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        downloadDir = base.appendingPathComponent("VideoOrganizer/downloads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.app.error("Failed to create download directory: \(error.localizedDescription, privacy: .public)")
        }
        manifestPath = downloadDir.appendingPathComponent("_manifest.json")
        loadManifest()
    }

    // MARK: - Queries

    func isDownloaded(_ videoId: String) -> Bool {
        if case .completed(let p) = statuses[videoId] {
            return FileManager.default.fileExists(atPath: p)
        }
        return false
    }

    func isActive(_ videoId: String) -> Bool {
        if case .downloading = statuses[videoId] { return true }
        return false
    }

    func progress(for videoId: String) -> Double {
        if case .downloading(let p) = statuses[videoId] { return p }
        return 0
    }

    func localURL(for videoId: String) -> URL? {
        guard case .completed(let p) = statuses[videoId],
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    // MARK: - Actions

    func download(videoId: String) {
        guard !isDownloaded(videoId), !isActive(videoId) else { return }
        statuses[videoId] = .downloading(progress: 0)

        Task { [weak self] in
            await self?.runDownload(videoId: videoId)
        }
    }

    func cancel(videoId: String) {
        processes[videoId]?.terminate()
        processes.removeValue(forKey: videoId)
        statuses[videoId] = .idle
    }

    func deleteDownload(videoId: String) {
        cancel(videoId: videoId)
        let file = downloadDir.appendingPathComponent("\(videoId).mp4")
        removeItemIfPresent(at: file, label: "download file")
        let partFile = downloadDir.appendingPathComponent("\(videoId).mp4.part")
        removeItemIfPresent(at: partFile, label: "partial download file")
        statuses.removeValue(forKey: videoId)
        saveManifest()
    }

    func playOffline(videoId: String) {
        guard let url = localURL(for: videoId) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Download Process

    private func runDownload(videoId: String) async {
        let outputTemplate = downloadDir.appendingPathComponent("\(videoId).%(ext)s").path
        let expectedOutput = downloadDir.appendingPathComponent("\(videoId).mp4").path
        let url = "https://www.youtube.com/watch?v=\(videoId)"

        let ytdlp = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let execPath = ytdlp else {
            statuses[videoId] = .failed(message: "yt-dlp not found. Install via: brew install yt-dlp")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = [
            "-f", "bv*[height<=720]+ba/b[height<=720]",
            "--concurrent-fragments", "4",
            "-c",
            "--merge-output-format", "mp4",
            "--retries", "3",
            "--fragment-retries", "3",
            "--no-playlist",
            "--newline",
            "-o", outputTemplate,
            url
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            processes[videoId] = process
            try process.run()
        } catch {
            statuses[videoId] = .failed(message: "Failed to start yt-dlp: \(error.localizedDescription)")
            processes.removeValue(forKey: videoId)
            return
        }

        // Read output for progress updates
        let handle = pipe.fileHandleForReading
        Task.detached { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let range = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    if let pct = Self.parseProgress(line) {
                        await MainActor.run { [weak self] in
                            self?.statuses[videoId] = .downloading(progress: pct)
                        }
                    }
                }
            }
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
        }

        processes.removeValue(forKey: videoId)

        if exitCode == 0, FileManager.default.fileExists(atPath: expectedOutput) {
            statuses[videoId] = .completed(path: expectedOutput)
            saveManifest()
            AppLogger.app.info("Download complete: \(videoId, privacy: .public)")
        } else if exitCode == 0 {
            // File might have a different extension — find it
            let candidates = candidateOutputFiles(for: videoId)
            if let found = candidates?.first {
                statuses[videoId] = .completed(path: found.path)
                saveManifest()
            } else {
                statuses[videoId] = .failed(message: "yt-dlp finished but output file not found")
            }
        } else {
            statuses[videoId] = .failed(message: "yt-dlp exited with code \(exitCode)")
        }
    }

    /// Parse yt-dlp download progress. Lines look like:
    /// `[download]  45.2% of ~12.34MiB at  1.23MiB/s ETA 00:08`
    nonisolated static func parseProgress(_ line: String) -> Double? {
        guard line.contains("%") else { return nil }
        // Find the first number followed by %
        let pattern = #"(\d+\.?\d*)\s*%"#
        guard let match = line.range(of: pattern, options: .regularExpression),
              let value = Double(line[match].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)),
              value <= 100
        else { return nil }
        return value / 100.0
    }

    // MARK: - Manifest

    private func saveManifest() {
        var manifest: [String: String] = [:]
        for (id, status) in statuses {
            if case .completed(let path) = status { manifest[id] = path }
        }
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestPath, options: .atomic)
        } catch {
            AppLogger.app.error("Failed to save download manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadManifest() {
        guard FileManager.default.fileExists(atPath: manifestPath.path) else { return }

        let manifest: [String: String]
        do {
            let data = try Data(contentsOf: manifestPath)
            manifest = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            AppLogger.app.error("Failed to load download manifest: \(error.localizedDescription, privacy: .public)")
            return
        }

        for (id, path) in manifest where FileManager.default.fileExists(atPath: path) {
            statuses[id] = .completed(path: path)
        }
    }

    private func candidateOutputFiles(for videoId: String) -> [URL]? {
        do {
            return try FileManager.default.contentsOfDirectory(at: downloadDir, includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix(videoId) &&
                !$0.lastPathComponent.hasSuffix(".part") &&
                $0.lastPathComponent != "_manifest.json"
            }
        } catch {
            AppLogger.app.error("Failed to inspect download directory for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func removeItemIfPresent(at url: URL, label: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLogger.app.error("Failed to remove \(label, privacy: .public) at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
