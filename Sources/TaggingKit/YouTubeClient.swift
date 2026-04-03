import Foundation

/// Lightweight YouTube Data API v3 client for fetching video metadata.
public struct YouTubeClient: Sendable {
    private enum AuthorizationMode {
        case apiKeyOnly
        case bearerIfAvailable
    }

    private let apiKey: String
    private let accessToken: String?
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
        self.accessToken = ProcessInfo.processInfo.environment["YOUTUBE_ACCESS_TOKEN"]
            ?? ProcessInfo.processInfo.environment["GOOGLE_OAUTH_ACCESS_TOKEN"]
            ?? YouTubeOAuthTokenStore().load()?.accessToken
    }

    /// Resolve API key from parameter, env var, or config file.
    public init(session: URLSession = .shared) throws {
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
        self.session = session
        self.accessToken = ProcessInfo.processInfo.environment["YOUTUBE_ACCESS_TOKEN"]
            ?? ProcessInfo.processInfo.environment["GOOGLE_OAUTH_ACCESS_TOKEN"]
            ?? YouTubeOAuthTokenStore().load()?.accessToken
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

        let (data, response) = try await requestData(from: components.url!, authorization: .apiKeyOnly)

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

        let (data, response) = try await requestData(from: components.url!, authorization: .apiKeyOnly)

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
        progress: (@Sendable (Int, Int) -> Void)? = nil
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
    /// Fetch full channel details (snippet + statistics) for multiple channel IDs, batching 50 at a time.
    public func fetchChannelDetails(
        channelIds: [String],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [ChannelRecord] {
        var results: [ChannelRecord] = []
        let batches = stride(from: 0, to: channelIds.count, by: 50).map {
            Array(channelIds[$0..<min($0 + 50, channelIds.count)])
        }

        var consecutiveErrors = 0
        for (index, batch) in batches.enumerated() {
            progress?(index + 1, batches.count)

            if index > 0 {
                try? await Task.sleep(for: .milliseconds(200))
            }

            do {
                let batchIds = batch.joined(separator: ",")
                var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
                components.queryItems = [
                    URLQueryItem(name: "part", value: "snippet,statistics"),
                    URLQueryItem(name: "id", value: batchIds),
                    URLQueryItem(name: "key", value: apiKey)
                ]

                let (data, response) = try await requestData(from: components.url!, authorization: .apiKeyOnly)
                guard let http = response as? HTTPURLResponse else {
                    throw YouTubeError.invalidResponse
                }
                guard http.statusCode == 200 else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw YouTubeError.apiError(statusCode: http.statusCode, message: body)
                }

                let decoded = try JSONDecoder().decode(ChannelDetailResponse.self, from: data)
                let now = ISO8601DateFormatter().string(from: Date())
                for item in decoded.items {
                    let record = ChannelRecord(
                        channelId: item.id,
                        name: item.snippet?.title ?? item.id,
                        handle: item.snippet?.customUrl,
                        channelUrl: "https://www.youtube.com/channel/\(item.id)",
                        iconUrl: item.snippet?.thumbnails?.defaultThumbnail?.url,
                        subscriberCount: item.statistics?.subscriberCount,
                        description: item.snippet?.description,
                        videoCountTotal: item.statistics?.videoCount.flatMap { Int($0) },
                        fetchedAt: now
                    )
                    results.append(record)
                }
                consecutiveErrors = 0
            } catch let error as YouTubeError {
                consecutiveErrors += 1
                if case .apiError(let code, _) = error, (code == 403 || code == 429) {
                    let backoff = min(60, 2 * consecutiveErrors)
                    print("  ⚠ Rate limited on channel batch \(index + 1). Waiting \(backoff)s...")
                    try? await Task.sleep(for: .seconds(backoff))
                    if consecutiveErrors >= 3 {
                        print("  ✘ 3 consecutive failures. Stopping — got \(results.count) channels.")
                        break
                    }
                } else {
                    print("  ⚠ Channel batch \(index + 1) failed: \(error.localizedDescription). Skipping.")
                }
            }
        }

        return results
    }

    /// Download a channel icon image and return the raw bytes.
    public func downloadChannelIcon(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw YouTubeError.invalidResponse
        }
        return data
    }

    public func searchChannelVideos(
        channelId: String,
        order: ChannelSearchOrder,
        maxResults: Int = 8
    ) async throws -> [DiscoveredVideo] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "channelId", value: channelId),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "order", value: order.rawValue),
            URLQueryItem(name: "maxResults", value: String(max(1, min(maxResults, 25)))),
            URLQueryItem(name: "key", value: apiKey)
        ]

        let (data, response) = try await requestData(from: components.url!, authorization: .apiKeyOnly)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw YouTubeError.apiError(statusCode: http.statusCode, message: body)
        }

        let result = try JSONDecoder().decode(SearchResponse.self, from: data)
        let ids = result.items.compactMap { $0.id.videoId }
        let metadataById = try await Dictionary(
            uniqueKeysWithValues: fetchVideoMetadata(ids: ids).map { ($0.videoId, $0) }
        )

        return result.items.compactMap { item in
            guard let videoId = item.id.videoId else { return nil }
            let metadata = metadataById[videoId]
            return DiscoveredVideo(
                videoId: videoId,
                title: item.snippet.title ?? "Untitled",
                channelId: item.snippet.channelId ?? metadata?.channelId,
                channelTitle: item.snippet.channelTitle ?? metadata?.channelTitle,
                publishedAt: metadata?.formattedDate ?? VideoMetadata(videoId: videoId, viewCount: nil, publishedAt: item.snippet.publishedAt, duration: nil, channelId: nil, channelTitle: nil).formattedDate,
                duration: metadata?.formattedDuration,
                viewCount: metadata?.formattedViewCount,
                sourceOrder: order
            )
        }
    }

    public func fetchPlaylistItems(playlistId: String) async throws -> [PlaylistVideoItem] {
        var results: [PlaylistVideoItem] = []
        var nextPageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "playlistId", value: playlistId),
                URLQueryItem(name: "maxResults", value: "50"),
                URLQueryItem(name: "key", value: apiKey)
            ]
            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }
            components.queryItems = queryItems

            let (data, response) = try await requestData(from: components.url!, authorization: .bearerIfAvailable)
            guard let http = response as? HTTPURLResponse else {
                throw YouTubeError.invalidResponse
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw YouTubeError.apiError(statusCode: http.statusCode, message: body)
            }

            let decoded = try JSONDecoder().decode(PlaylistItemsResponse.self, from: data)
            for item in decoded.items {
                guard let videoId = item.snippet.resourceId.videoId else { continue }
                results.append(PlaylistVideoItem(
                    videoId: videoId,
                    title: item.snippet.title,
                    channelId: item.snippet.videoOwnerChannelId ?? item.snippet.channelId,
                    channelTitle: item.snippet.videoOwnerChannelTitle ?? item.snippet.channelTitle,
                    position: item.snippet.position ?? results.count
                ))
            }
            nextPageToken = decoded.nextPageToken
        } while nextPageToken != nil

        return results
    }

    private func requestData(from url: URL, authorization: AuthorizationMode) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if authorization == .bearerIfAvailable, let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return try await session.data(for: request)
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

public struct DiscoveredVideo: Sendable {
    public let videoId: String
    public let title: String
    public let channelId: String?
    public let channelTitle: String?
    public let publishedAt: String?
    public let duration: String?
    public let viewCount: String?
    public let sourceOrder: ChannelSearchOrder
}

public enum ChannelSearchOrder: String, Sendable {
    case date
    case viewCount
}

public struct PlaylistVideoItem: Sendable {
    public let videoId: String
    public let title: String?
    public let channelId: String?
    public let channelTitle: String?
    public let position: Int
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

private struct ChannelDetailResponse: Decodable {
    let items: [ChannelDetailItem]
}

private struct SearchResponse: Decodable {
    let items: [SearchItem]
}

private struct SearchItem: Decodable {
    let id: SearchItemID
    let snippet: SearchSnippet
}

private struct SearchItemID: Decodable {
    let videoId: String?
}

private struct SearchSnippet: Decodable {
    let publishedAt: String?
    let channelId: String?
    let channelTitle: String?
    let title: String?
}

private struct PlaylistItemsResponse: Decodable {
    let nextPageToken: String?
    let items: [PlaylistItemsResponseItem]
}

private struct PlaylistItemsResponseItem: Decodable {
    let snippet: PlaylistItemsSnippet
}

private struct PlaylistItemsSnippet: Decodable {
    let title: String?
    let channelId: String?
    let channelTitle: String?
    let videoOwnerChannelId: String?
    let videoOwnerChannelTitle: String?
    let position: Int?
    let resourceId: PlaylistResourceID
}

private struct PlaylistResourceID: Decodable {
    let videoId: String?
}

private struct ChannelDetailItem: Decodable {
    let id: String
    let snippet: ChannelDetailSnippet?
    let statistics: ChannelStatistics?

    struct ChannelDetailSnippet: Decodable {
        let title: String?
        let description: String?
        let customUrl: String?
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

    struct ChannelStatistics: Decodable {
        let subscriberCount: String?
        let videoCount: String?
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
            return "YouTube API error (\(code)): \(Self.compactMessage(from: message))"
        }
    }

    private static func compactMessage(from raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let message = payload.error.message, !message.isEmpty {
            return message
        }

        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorPayload
    }

    private struct ErrorPayload: Decodable {
        let message: String?
    }
}
