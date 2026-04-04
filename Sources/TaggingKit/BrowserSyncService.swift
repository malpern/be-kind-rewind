import Foundation

public struct BrowserSyncResult: Sendable {
    public let syncedActionIDs: [Int64]
    public let failures: [SyncFailureRecord]
}

public struct BrowserExecutorStatus: Sendable {
    public let ready: Bool
    public let message: String

    public init(ready: Bool, message: String) {
        self.ready = ready
        self.message = message
    }
}

public struct BrowserSyncService: Sendable {
    private let environment: RuntimeEnvironment

    public init(environment: RuntimeEnvironment) {
        self.environment = environment
    }

    public init(repoRoot: URL) {
        self.environment = RuntimeEnvironment(currentDirectoryURL: repoRoot, bundleURL: nil)
    }

    public func execute(actions: [SyncAction]) async throws -> BrowserSyncResult {
        guard !actions.isEmpty else {
            return BrowserSyncResult(syncedActionIDs: [], failures: [])
        }

        let scriptURL = environment.scriptURL(named: "youtube_browser_sync.mjs")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-browser-sync-\(UUID().uuidString).json")

        let payload = BrowserSyncPayload(actions: actions.map {
            BrowserSyncPayload.Action(
                id: $0.id,
                action: $0.action,
                videoId: $0.videoId,
                playlistId: $0.playlist,
                playlistTitle: playlistTitle(for: $0)
            )
        })
        let data = try JSONEncoder().encode(payload)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let artifactDir = environment
            .browserSyncArtifactsDirectory()
            .appendingPathComponent(Self.timestampedRunDirectory())
        let arguments = [
            "npx", "--yes", "--package", "playwright",
            "node", scriptURL.path,
            "--actions-json", tempURL.path,
            "--artifact-dir", artifactDir.path
        ]
        let execution = try await runProcess(arguments: arguments)

        guard execution.terminationStatus == 0 else {
            let stderrText = String(data: execution.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BrowserSyncError.executionFailed(stderrText.isEmpty ? "Browser sync failed." : stderrText)
        }

        let response = try JSONDecoder().decode(BrowserSyncResponse.self, from: execution.stdout)
        return BrowserSyncResult(
            syncedActionIDs: response.successes,
            failures: response.failures.map { SyncFailureRecord(id: $0.id, message: $0.message) }
        )
    }

    public func openLoginSetup() async throws {
        let scriptURL = environment.scriptURL(named: "youtube_browser_sync.mjs")
        let process = Process()
        process.currentDirectoryURL = environment.repoRoot()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "npx", "--yes", "--package", "playwright",
            "node", scriptURL.path,
            "--setup-login", "true"
        ]
        try process.run()
    }

    public func status() async throws -> BrowserExecutorStatus {
        let profileRunning = (try? isBrowserProfileProcessRunning()) ?? false
        let hasSession = (try? profileHasSignedInYouTubeSession()) ?? false

        if hasSession && profileRunning {
            return BrowserExecutorStatus(
                ready: false,
                message: "Signed in to YouTube. Close the dedicated browser-sync Chrome window when you're ready for the app to use browser fallback actions."
            )
        }

        if hasSession {
            return BrowserExecutorStatus(
                ready: true,
                message: "Signed in to YouTube"
            )
        }

        if profileRunning {
            return BrowserExecutorStatus(
                ready: false,
                message: "Browser sign-in window is open. Finish signing in there, then close it and refresh sync status."
            )
        }

        return BrowserExecutorStatus(
            ready: false,
            message: "Browser executor is not signed in. Open Browser Sign-In to connect the dedicated Chrome profile."
        )
    }

    private func playlistTitle(for action: SyncAction) -> String? {
        if action.playlist == "WL" {
            return "Watch Later"
        }
        return action.playlistTitle
    }

    private static func timestampedRunDirectory() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func runProcess(arguments: [String]) async throws -> ProcessExecutionResult {
        let process = Process()
        process.currentDirectoryURL = environment.repoRoot()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ProcessExecutionResult(
                    terminationStatus: process.terminationStatus,
                    stdout: stdoutData,
                    stderr: stderrData
                ))
            }
        }
    }

    private func isBrowserProfileProcessRunning() throws -> Bool {
        let profileDir = environment.playwrightProfileDirectory()
        let execution = try runProcessSync(arguments: ["pgrep", "-fal", profileDir.path])
        guard execution.terminationStatus == 0,
              let output = String(data: execution.stdout, encoding: .utf8)?
                .lowercased(),
              !output.isEmpty else {
            return false
        }
        return output.contains(profileDir.path.lowercased())
    }

    private func runProcessSync(arguments: [String]) throws -> ProcessExecutionResult {
        let process = Process()
        process.currentDirectoryURL = environment.repoRoot()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return ProcessExecutionResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func profileHasSignedInYouTubeSession() throws -> Bool {
        let cookiesPath = environment.playwrightProfileDirectory()
            .appendingPathComponent("Default")
            .appendingPathComponent("Cookies")
            .path

        guard FileManager.default.fileExists(atPath: cookiesPath) else {
            return false
        }

        let query = """
        SELECT 1
        FROM cookies
        WHERE (host_key = '.youtube.com' AND name = 'LOGIN_INFO')
           OR (host_key = '.youtube.com' AND name = 'SID')
           OR (host_key = '.google.com' AND name = 'SID')
        LIMIT 1;
        """
        let execution = try runProcessSync(arguments: ["sqlite3", cookiesPath, query])
        guard execution.terminationStatus == 0,
              let output = String(data: execution.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return output == "1"
    }
}

public enum BrowserSyncError: Error, LocalizedError {
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return message
        }
    }
}

private struct BrowserSyncPayload: Encodable {
    let actions: [Action]

    struct Action: Encodable {
        let id: Int64
        let action: String
        let videoId: String
        let playlistId: String
        let playlistTitle: String?
    }
}

private struct BrowserSyncResponse: Decodable {
    let successes: [Int64]
    let failures: [Failure]

    struct Failure: Decodable {
        let id: Int64
        let message: String
    }
}

private struct ProcessExecutionResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}
