import Foundation

public struct RuntimeEnvironment: Sendable {
    public let currentDirectoryURL: URL
    public let bundleURL: URL?
    public let applicationName: String
    public let homeDirectoryURL: URL
    public let applicationSupportDirectoryURL: URL?

    public init(
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        bundleURL: URL? = Bundle.main.bundleURL,
        applicationName: String = "Be Kind Rewind",
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectoryURL: URL? = nil
    ) {
        self.currentDirectoryURL = currentDirectoryURL
        self.bundleURL = bundleURL
        self.applicationName = applicationName
        self.homeDirectoryURL = homeDirectoryURL
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
    }

    public func repoRoot(fileManager: FileManager = .default) -> URL {
        if fileManager.fileExists(atPath: currentDirectoryURL.appendingPathComponent("scripts/youtube_browser_sync.mjs").path) {
            return currentDirectoryURL
        }

        if let bundleURL, bundleURL.pathExtension == "app" {
            let candidate = bundleURL.deletingLastPathComponent()
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("scripts/youtube_browser_sync.mjs").path) {
                return candidate
            }
        }

        return currentDirectoryURL
    }

    public func scriptURL(named name: String, fileManager: FileManager = .default) -> URL {
        repoRoot(fileManager: fileManager).appendingPathComponent("scripts/\(name)")
    }

    public func browserSyncArtifactsDirectory(fileManager: FileManager = .default) -> URL {
        repoRoot(fileManager: fileManager).appendingPathComponent("output/playwright/browser-sync")
    }

    public func playwrightProfileDirectory() -> URL {
        homeDirectoryURL.appendingPathComponent(".config/be-kind-rewind/playwright-profile")
    }

    public func defaultDatabaseURL(
        filename: String = "video-tagger.db",
        fileManager: FileManager = .default
    ) -> URL {
        if let applicationSupportDirectoryURL {
            return applicationSupportDirectoryURL
                .appendingPathComponent(applicationName, isDirectory: true)
                .appendingPathComponent(filename)
        }

        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? currentDirectoryURL

        return appSupport
            .appendingPathComponent(applicationName, isDirectory: true)
            .appendingPathComponent(filename)
    }

    public func preferredDatabaseURL(
        legacyCandidates: [URL],
        filename: String = "video-tagger.db",
        fileManager: FileManager = .default
    ) -> URL {
        for candidate in legacyCandidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        return defaultDatabaseURL(filename: filename, fileManager: fileManager)
    }
}
