import Foundation

public struct DiscoveryFallbackVideo: Sendable {
    public let videoId: String
    public let title: String
    public let channelTitle: String?
    public let publishedAt: String?
    public let duration: String?
    public let viewCount: String?
    public let source: String
}

public struct DiscoveryFallbackService: Sendable {
    private let repoRoot: URL
    private let pythonExecutable: URL

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
        let bundledPython = repoRoot
            .appendingPathComponent(".runtime/discovery-venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: bundledPython.path) {
            self.pythonExecutable = bundledPython
        } else {
            self.pythonExecutable = URL(fileURLWithPath: "/usr/bin/python3")
        }
    }

    public func fetchRecentChannelUploads(channelId: String, maxResults: Int = 16) async throws -> [DiscoveryFallbackVideo] {
        let scriptURL = repoRoot.appendingPathComponent("scripts/youtube_channel_fallback.py")
        let arguments = [
            pythonExecutable.path,
            scriptURL.path,
            "--channel-id", channelId,
            "--max-results", String(max(1, min(maxResults, 50)))
        ]
        let execution = try await runProcess(arguments: arguments)

        guard execution.terminationStatus == 0 else {
            let stderrText = String(data: execution.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DiscoveryFallbackError.executionFailed(stderrText.isEmpty ? "Channel fallback discovery failed." : stderrText)
        }

        let response = try JSONDecoder().decode(DiscoveryFallbackResponse.self, from: execution.stdout)
        return response.videos.map {
            DiscoveryFallbackVideo(
                videoId: $0.videoId,
                title: $0.title,
                channelTitle: $0.channelTitle,
                publishedAt: $0.publishedAt,
                duration: $0.duration,
                viewCount: $0.viewCount,
                source: response.source
            )
        }
    }

    private func runProcess(arguments: [String]) async throws -> ProcessExecutionResult {
        let process = Process()
        process.currentDirectoryURL = repoRoot
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
}

public enum DiscoveryFallbackError: Error, LocalizedError {
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return message
        }
    }
}

private struct DiscoveryFallbackResponse: Decodable {
    let source: String
    let videos: [Video]

    struct Video: Decodable {
        let videoId: String
        let title: String
        let channelTitle: String?
        let publishedAt: String?
        let duration: String?
        let viewCount: String?
    }
}

private struct ProcessExecutionResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}
