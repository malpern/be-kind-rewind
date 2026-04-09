import AppKit
import Foundation

/// Downloads and caches YouTube thumbnails to disk for instant offline loading.
@MainActor
@Observable
final class ThumbnailCache {
    private(set) var downloadedCount = 0
    private(set) var totalCount = 0
    private(set) var isDownloading = false

    private let cacheDir: URL
    private let session: URLSession

    init(cacheDir: URL? = nil, session: URLSession? = nil) {
        let resolvedCacheDir = cacheDir ?? {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            return base.appendingPathComponent("VideoOrganizer/thumbnails", isDirectory: true)
        }()
        self.cacheDir = resolvedCacheDir
        try? FileManager.default.createDirectory(at: resolvedCacheDir, withIntermediateDirectories: true)

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = 10
            self.session = URLSession(configuration: config)
        }
    }

    /// Get the local path for a thumbnail. Returns nil if not yet cached.
    func localURL(for videoId: String) -> URL? {
        let path = cacheDir.appendingPathComponent("\(videoId).jpg")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Load a thumbnail as NSImage, falling back to network if not cached.
    nonisolated func loadImage(videoId: String, cacheDir: URL) -> NSImage? {
        let path = cacheDir.appendingPathComponent("\(videoId).jpg")
        guard FileManager.default.fileExists(atPath: path.path),
              let image = NSImage(contentsOf: path) else {
            return nil
        }
        return image
    }

    /// The cache directory URL for use in non-isolated contexts.
    var cacheDirURL: URL { cacheDir }

    /// Download thumbnails for all video IDs that aren't already cached.
    func prefetch(videoIds: [String]) async {
        let uncached = videoIds.filter { localURL(for: $0) == nil }
        guard !uncached.isEmpty else { return }

        isDownloading = true
        totalCount = uncached.count
        downloadedCount = 0

        await withTaskGroup(of: Void.self) { group in
            for videoId in uncached {
                group.addTask { [session, cacheDir] in
                    let url = URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")!
                    let destPath = cacheDir.appendingPathComponent("\(videoId).jpg")

                    do {
                        let (data, response) = try await session.data(from: url)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                        try data.write(to: destPath)
                    } catch {
                        // Silently skip failed downloads
                    }
                }
            }

            for await _ in group {
                downloadedCount += 1
            }
        }

        isDownloading = false
    }
}
