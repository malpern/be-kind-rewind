import Foundation

public struct DiscoveryFallbackVideo: Sendable {
    public let videoId: String
    public let title: String
    public let channelTitle: String?
    public let publishedAt: String?
    public let duration: String?
    public let viewCount: String?
    public let source: String
    public let channelId: String?

    public init(videoId: String, title: String, channelTitle: String?, publishedAt: String?,
                duration: String?, viewCount: String?, source: String, channelId: String? = nil) {
        self.videoId = videoId
        self.title = title
        self.channelTitle = channelTitle
        self.publishedAt = publishedAt
        self.duration = duration
        self.viewCount = viewCount
        self.source = source
        self.channelId = channelId
    }
}

public struct DiscoveryFallbackService: Sendable {
    private let environment: RuntimeEnvironment
    private let pythonExecutable: URL

    public init(environment: RuntimeEnvironment) {
        self.environment = environment
        let bundledPython = environment.repoRoot()
            .appendingPathComponent(".runtime/discovery-venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: bundledPython.path) {
            self.pythonExecutable = bundledPython
        } else {
            self.pythonExecutable = URL(fileURLWithPath: "/usr/bin/python3")
        }
    }

    public init(repoRoot: URL) {
        self.init(environment: RuntimeEnvironment(currentDirectoryURL: repoRoot, bundleURL: nil))
    }

    public func fetchRecentChannelUploads(channelId: String, maxResults: Int = 16) async throws -> [DiscoveryFallbackVideo] {
        // Cap raised from 50 to 400 across Phase 3 to support deeper catalogs
        // on the creator detail page. Most channels return well under 200
        // results, so the cap mostly matters for prolific creators. The
        // default for incremental discovery (16) and existing refresh callers
        // are unchanged — only the explicit "Load full history" path uses the
        // wide cap.
        //
        // Phase 3 politeness layer: every scrape goes through ScrapeRateLimiter
        // first. It enforces a 2-second minimum interval between attempts, a
        // 5-minute global cooldown after blocking-pattern failures, and a
        // 10-minute per-channel cooldown after any failure on the same channel.
        // This bounds our request rate so we don't get our scraping IP banned.
        await ScrapeRateLimiter.shared.waitForSlot(channelId: channelId)
        await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
            kind: .channelArchive,
            backend: .scrape,
            outcome: .started,
            detail: "channel_id=\(channelId) max_results=\(maxResults)"
        )
        let scriptURL = environment.scriptURL(named: "youtube_channel_fallback.py")
        let arguments = [
            pythonExecutable.path,
            scriptURL.path,
            "--channel-id", channelId,
            "--max-results", String(max(1, min(maxResults, 400)))
        ]
        let execution: ProcessExecutionResult
        do {
            execution = try await runProcess(arguments: arguments)
        } catch {
            // Process-level failure (timeout, signal, executable missing).
            // Tell the rate limiter and the ledger and propagate.
            await ScrapeRateLimiter.shared.recordFailure(channelId: channelId, reason: error.localizedDescription)
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: .channelArchive,
                backend: .scrape,
                outcome: .failed,
                detail: "channel_id=\(channelId) process=\(error.localizedDescription)"
            )
            throw error
        }

        guard execution.terminationStatus == 0 else {
            let stderrText = String(data: execution.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reason = stderrText.isEmpty ? "channel_id=\(channelId)" : stderrText
            await ScrapeRateLimiter.shared.recordFailure(channelId: channelId, reason: reason)
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: .channelArchive,
                backend: .scrape,
                outcome: .failed,
                detail: reason
            )
            throw DiscoveryFallbackError.executionFailed(stderrText.isEmpty ? "Channel fallback discovery failed." : stderrText)
        }

        let response = try JSONDecoder().decode(DiscoveryFallbackResponse.self, from: execution.stdout)
        await ScrapeRateLimiter.shared.recordSuccess(channelId: channelId)
        await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
            kind: .channelArchive,
            backend: response.source == "rss" ? .rss : .scrape,
            outcome: .succeeded,
            detail: "channel_id=\(channelId) videos=\(response.videos.count)"
        )
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

    public func searchVideos(query: String, maxResults: Int = 5) async throws -> [DiscoveryFallbackVideo] {
        // Phase 3 politeness: search scraping goes through the same rate
        // limiter as channel archive scraping. Per-channel cooldown doesn't
        // apply (no channel id), but the global minimum interval and the
        // global blocked cooldown both still gate this path.
        await ScrapeRateLimiter.shared.waitForSlot(channelId: nil)
        await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
            kind: .search,
            backend: .scrape,
            outcome: .started,
            detail: "query=\(query) max_results=\(maxResults)"
        )
        let scriptURL = environment.scriptURL(named: "youtube_search_fallback.py")
        let arguments = [
            pythonExecutable.path,
            scriptURL.path,
            "--query", query,
            "--max-results", String(max(1, min(maxResults, 20)))
        ]
        let execution: ProcessExecutionResult
        do {
            execution = try await runProcess(arguments: arguments)
        } catch {
            await ScrapeRateLimiter.shared.recordFailure(channelId: nil, reason: error.localizedDescription)
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: .search,
                backend: .scrape,
                outcome: .failed,
                detail: "query=\(query) process=\(error.localizedDescription)"
            )
            throw error
        }

        guard execution.terminationStatus == 0 else {
            let stderrText = String(data: execution.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reason = stderrText.isEmpty ? "query=\(query)" : stderrText
            await ScrapeRateLimiter.shared.recordFailure(channelId: nil, reason: reason)
            await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
                kind: .search,
                backend: .scrape,
                outcome: .failed,
                detail: reason
            )
            throw DiscoveryFallbackError.executionFailed(stderrText.isEmpty ? "Search fallback failed." : stderrText)
        }

        let response = try JSONDecoder().decode(SearchFallbackResponse.self, from: execution.stdout)
        await ScrapeRateLimiter.shared.recordSuccess(channelId: nil)
        await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
            kind: .search,
            backend: .scrape,
            outcome: .succeeded,
            detail: "query=\(query) videos=\(response.videos.count)"
        )
        return response.videos.map {
            DiscoveryFallbackVideo(
                videoId: $0.videoId,
                title: $0.title,
                channelTitle: $0.channelTitle,
                publishedAt: $0.publishedAt,
                duration: $0.duration,
                viewCount: $0.viewCount,
                source: response.source,
                channelId: $0.channelId
            )
        }
    }

    private func runProcess(arguments: [String], timeout: Duration = .seconds(60)) async throws -> ProcessExecutionResult {
        let process = Process()
        process.currentDirectoryURL = environment.repoRoot()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        return try await withThrowingTaskGroup(of: ProcessExecutionResult.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
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
            group.addTask {
                try await Task.sleep(for: timeout)
                process.terminate()
                throw DiscoveryFallbackError.executionFailed("Process timed out after \(timeout)")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
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

private struct SearchFallbackResponse: Decodable {
    let source: String
    let videos: [Video]

    struct Video: Decodable {
        let videoId: String
        let title: String
        let channelId: String?
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
