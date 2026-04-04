import Foundation
import Testing
@testable import TaggingKit

@Suite("RuntimeEnvironment")
struct RuntimeEnvironmentTests {
    @Test("repoRoot prefers current directory when scripts exist there")
    func repoRootUsesCurrentDirectory() throws {
        try withTemporaryDirectory { directory in
            let scripts = directory.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            let script = scripts.appendingPathComponent("youtube_browser_sync.mjs")
            try Data().write(to: script)

            let environment = RuntimeEnvironment(
                currentDirectoryURL: directory,
                bundleURL: nil,
                applicationSupportDirectoryURL: directory.appendingPathComponent("AppSupport", isDirectory: true)
            )

            #expect(environment.repoRoot() == directory)
            #expect(environment.scriptURL(named: "youtube_browser_sync.mjs") == script)
        }
    }

    @Test("repoRoot resolves from app bundle parent when running from an app")
    func repoRootUsesBundleParent() throws {
        try withTemporaryDirectory { directory in
            let repoRoot = directory.appendingPathComponent("workspace", isDirectory: true)
            let scripts = repoRoot.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try Data().write(to: scripts.appendingPathComponent("youtube_browser_sync.mjs"))
            try FileManager.default.createDirectory(
                at: repoRoot.appendingPathComponent("VideoOrganizer.app", isDirectory: true),
                withIntermediateDirectories: true
            )

            let environment = RuntimeEnvironment(
                currentDirectoryURL: directory,
                bundleURL: repoRoot.appendingPathComponent("VideoOrganizer.app", isDirectory: true),
                applicationSupportDirectoryURL: directory.appendingPathComponent("AppSupport", isDirectory: true)
            )

            #expect(environment.repoRoot() == repoRoot)
        }
    }

    @Test("preferredDatabaseURL preserves legacy databases and otherwise uses Application Support")
    func preferredDatabaseURLSelection() throws {
        try withTemporaryDirectory { directory in
            let appSupport = directory.appendingPathComponent("App Support", isDirectory: true)
            let legacy = directory.appendingPathComponent("video-tagger.db")
            try Data().write(to: legacy)

            let environment = RuntimeEnvironment(
                currentDirectoryURL: directory,
                bundleURL: nil,
                applicationSupportDirectoryURL: appSupport
            )

            #expect(environment.preferredDatabaseURL(legacyCandidates: [legacy]) == legacy)

            try FileManager.default.removeItem(at: legacy)
            let fallback = environment.preferredDatabaseURL(legacyCandidates: [legacy])
            #expect(fallback == appSupport.appendingPathComponent("Be Kind Rewind", isDirectory: true).appendingPathComponent("video-tagger.db"))
        }
    }
}

private func withTemporaryDirectory<Result>(
    _ body: (URL) throws -> Result
) throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}
