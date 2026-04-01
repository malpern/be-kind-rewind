import Foundation

/// Lightweight YouTube Data API v3 client for fetching video metadata.
public struct YouTubeClient: Sendable {
    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Resolve API key from parameter, env var, or config file.
    public init() throws {
        if let key = ProcessInfo.processInfo.environment["YOUTUBE_API_KEY"] ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"] {
            self.apiKey = key
        } else {
            let configPath = NSString("~/.config/youtube/api-key").expandingTildeInPath
            guard FileManager.default.fileExists(atPath: configPath),
                  let key = try? String(contentsOfFile: configPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                throw YouTubeError.noApiKey
            }
            self.apiKey = key
        }
    }

    /// Fetch metadata for up to 50 video IDs in a single request.
    public func fetchVideoMetadata(ids: [String]) async throws -> [VideoMetadata] {
        guard !ids.isEmpty else { return [] }
        let batchIds = ids.prefix(50).joined(separator: ",")

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet,contentDetails,statistics"),
            URLQueryItem(name: "id", value: batchIds),
            URLQueryItem(name: "key", value: apiKey)
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)

        guard let http = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw YouTubeError.apiError(statusCode: http.statusCode, message: body)
        }

        let result = try JSONDecoder().decode(YouTubeResponse.self, from: data)
        return result.items.map { item in
            VideoMetadata(
                videoId: item.id,
                viewCount: item.statistics?.viewCount,
                publishedAt: item.snippet?.publishedAt,
                duration: item.contentDetails?.duration,
                channelId: item.snippet?.channelId,
                channelTitle: item.snippet?.channelTitle
            )
        }
    }

    /// Fetch channel thumbnails for up to 50 channel IDs.
    public func fetchChannelThumbnails(channelIds: [String]) async throws -> [String: String] {
        guard !channelIds.isEmpty else { return [:] }
        let batchIds = channelIds.prefix(50).joined(separator: ",")

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "id", value: batchIds),
            URLQueryItem(name: "key", value: apiKey)
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return [:]
        }

        let result = try JSONDecoder().decode(ChannelResponse.self, from: data)
        var map: [String: String] = [:]
        for item in result.items {
            if let url = item.snippet?.thumbnails?.defaultThumbnail?.url {
                map[item.id] = url
            }
        }
        return map
    }

    /// Fetch metadata for all video IDs, batching 50 at a time.
    public func fetchAllVideoMetadata(
        ids: [String],
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> [VideoMetadata] {
        var results: [VideoMetadata] = []
        let batches = stride(from: 0, to: ids.count, by: 50).map {
            Array(ids[$0..<min($0 + 50, ids.count)])
        }

        var consecutiveErrors = 0
        for (index, batch) in batches.enumerated() {
            progress?(index + 1, batches.count)

            // Polite delay between requests (200ms baseline)
            if index > 0 {
                try? await Task.sleep(for: .milliseconds(200))
            }

            do {
                let metadata = try await fetchVideoMetadata(ids: batch)
                results.append(contentsOf: metadata)
                consecutiveErrors = 0
            } catch let error as YouTubeError {
                consecutiveErrors += 1
                if case .apiError(let code, _) = error, (code == 403 || code == 429) {
                    // Rate limited — back off exponentially
                    let backoff = min(60, 2 * consecutiveErrors)
                    print("  ⚠ Rate limited on batch \(index + 1). Waiting \(backoff)s...")
                    try? await Task.sleep(for: .seconds(backoff))

                    if consecutiveErrors >= 3 {
                        print("  ✘ 3 consecutive failures. Stopping — got \(results.count) videos. Re-run to continue.")
                        break
                    }

                    // Retry this batch once after backoff
                    do {
                        let metadata = try await fetchVideoMetadata(ids: batch)
                        results.append(contentsOf: metadata)
                        consecutiveErrors = 0
                    } catch {
                        print("  ✘ Retry failed. Stopping — got \(results.count) videos. Re-run to continue.")
                        break
                    }
                } else {
                    print("  ⚠ Batch \(index + 1) failed: \(error.localizedDescription). Skipping.")
                }
            }
        }

        return results
    }
}

// MARK: - Models

public struct VideoMetadata: Sendable {
    public let videoId: String
    public let viewCount: String?
    public let publishedAt: String?
    public let duration: String? // ISO 8601 duration, e.g. "PT15M33S"
    public let channelId: String?
    public let channelTitle: String?

    /// Human-readable view count, e.g. "1.2M views" or "340K views"
    public var formattedViewCount: String? {
        guard let str = viewCount, let count = Int(str) else { return nil }
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return String(format: "%.1fM views", millions)
        } else if count >= 1_000 {
            let thousands = Double(count) / 1_000
            return String(format: "%.0fK views", thousands)
        } else {
            return "\(count) views"
        }
    }

    /// Human-readable relative date, e.g. "2 years ago"
    public var formattedDate: String? {
        guard let dateStr = publishedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: dateStr)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: dateStr)
        }
        guard let date else { return nil }

        let now = Date()
        let interval = now.timeIntervalSince(date)
        let days = Int(interval / 86400)

        if days < 1 { return "today" }
        if days == 1 { return "1 day ago" }
        if days < 30 { return "\(days) days ago" }
        let months = days / 30
        if months == 1 { return "1 month ago" }
        if months < 12 { return "\(months) months ago" }
        let years = months / 12
        if years == 1 { return "1 year ago" }
        return "\(years) years ago"
    }

    /// Human-readable duration, e.g. "15:33" from ISO 8601 "PT15M33S"
    public var formattedDuration: String? {
        guard let iso = duration else { return nil }
        var remaining = iso.replacingOccurrences(of: "PT", with: "")
        var hours = 0, minutes = 0, seconds = 0

        if let hRange = remaining.range(of: "H") {
            hours = Int(remaining[remaining.startIndex..<hRange.lowerBound]) ?? 0
            remaining = String(remaining[hRange.upperBound...])
        }
        if let mRange = remaining.range(of: "M") {
            minutes = Int(remaining[remaining.startIndex..<mRange.lowerBound]) ?? 0
            remaining = String(remaining[mRange.upperBound...])
        }
        if let sRange = remaining.range(of: "S") {
            seconds = Int(remaining[remaining.startIndex..<sRange.lowerBound]) ?? 0
        }

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - API Response Types

private struct YouTubeResponse: Decodable {
    let items: [YouTubeVideoItem]
}

private struct YouTubeVideoItem: Decodable {
    let id: String
    let snippet: Snippet?
    let contentDetails: ContentDetails?
    let statistics: Statistics?

    struct Snippet: Decodable {
        let publishedAt: String?
        let channelId: String?
        let channelTitle: String?
    }

    struct ContentDetails: Decodable {
        let duration: String?
    }

    struct Statistics: Decodable {
        let viewCount: String?
    }
}

private struct ChannelResponse: Decodable {
    let items: [ChannelItem]
}

private struct ChannelItem: Decodable {
    let id: String
    let snippet: ChannelSnippet?

    struct ChannelSnippet: Decodable {
        let thumbnails: Thumbnails?

        struct Thumbnails: Decodable {
            let defaultThumbnail: Thumbnail?

            enum CodingKeys: String, CodingKey {
                case defaultThumbnail = "default"
            }

            struct Thumbnail: Decodable {
                let url: String?
            }
        }
    }
}

// MARK: - Errors

public enum YouTubeError: Error, LocalizedError {
    case noApiKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .noApiKey:
            return "No YouTube API key found. Set YOUTUBE_API_KEY or GOOGLE_API_KEY env var, or write key to ~/.config/youtube/api-key"
        case .invalidResponse:
            return "Invalid response from YouTube API"
        case .apiError(let code, let message):
            return "YouTube API error (\(code)): \(message)"
        }
    }
}
