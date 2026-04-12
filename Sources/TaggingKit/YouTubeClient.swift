import Foundation

/// Lightweight YouTube Data API v3 client for fetching video metadata.
public struct YouTubeClient: Sendable {
    enum AuthorizationMode {
        case apiKeyOnly
        case bearerIfAvailable
    }

    let apiKey: String
    let accessToken: String?
    let session: URLSession

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
        } else if let key = APIKeyStore().load(service: .youtube) {
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

    public static func hasStoredAPIKey() -> Bool {
        if let key = ProcessInfo.processInfo.environment["YOUTUBE_API_KEY"] ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"], !key.isEmpty {
            return true
        }
        if APIKeyStore().load(service: .youtube) != nil {
            return true
        }
        let configPath = NSString("~/.config/youtube/api-key").expandingTildeInPath
        return FileManager.default.fileExists(atPath: configPath)
    }

    public static func storeAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIKeyStoreError.invalidKeyFormat
        }
        try APIKeyStore().save(trimmed, service: .youtube)
    }

    public static func clearStoredAPIKey() {
        APIKeyStore().clear(service: .youtube)
    }

    func requestData(from url: URL, authorization: AuthorizationMode) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if authorization == .bearerIfAvailable, let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        await recordQuotaEvent(for: request, response: response)
        return (data, response)
    }

    func validWriteAccessToken() async throws -> String {
        if let envAccessToken = ProcessInfo.processInfo.environment["YOUTUBE_ACCESS_TOKEN"]
            ?? ProcessInfo.processInfo.environment["GOOGLE_OAUTH_ACCESS_TOKEN"],
           !envAccessToken.isEmpty {
            return envAccessToken
        }

        guard let config = try? YouTubeOAuthClientConfig.load() else {
            throw YouTubeError.noOAuthToken
        }

        let oauth = YouTubeOAuthService(config: config)
        if let stored = oauth.storedTokens(),
           !stored.includesScope(YouTubeOAuthService.writeScope) {
            throw YouTubeError.noOAuthToken
        }

        guard let refreshed = try await oauth.refreshIfNeeded() else {
            throw YouTubeError.noOAuthToken
        }
        return refreshed.accessToken
    }

    private func quotaOperation(for request: URLRequest) -> YouTubeAPIOperation {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .unknown
        }

        let path = components.path
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let part = queryItems["part"] ?? ""
        let method = request.httpMethod?.uppercased() ?? "GET"

        switch (method, path) {
        case ("GET", let p) where p.hasSuffix("/search"):
            return .searchList
        case ("GET", let p) where p.hasSuffix("/videos"):
            return .videosList
        case ("GET", let p) where p.hasSuffix("/channels"):
            if part.contains("contentDetails") {
                return .channelsListContentDetails
            }
            if part.contains("statistics") {
                return .channelsListStatistics
            }
            return .channelsListSnippet
        case ("GET", let p) where p.hasSuffix("/playlistItems"):
            return .playlistItemsList
        case ("POST", let p) where p.hasSuffix("/playlistItems"):
            return .playlistItemsInsert
        case ("DELETE", let p) where p.hasSuffix("/playlistItems"):
            return .playlistItemsDelete
        default:
            return .unknown
        }
    }

    private func quotaDetail(for request: URLRequest) -> String {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return request.url?.absoluteString ?? "unknown"
        }

        let filteredItems = (components.queryItems ?? []).filter { $0.name != "key" }
        if filteredItems.isEmpty {
            return components.path
        }
        let query = filteredItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return "\(components.path)?\(query)"
    }

    func recordQuotaEvent(for request: URLRequest, response: URLResponse) async {
        let operation = quotaOperation(for: request)
        let success = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        await YouTubeQuotaLedger.shared.recordAPIEvent(
            operation: operation,
            detail: quotaDetail(for: request),
            success: success
        )
        await YouTubeQuotaLedger.shared.recordDiscoveryEvent(
            kind: .other,
            backend: .api,
            outcome: success ? .succeeded : .failed,
            detail: "\(operation.label): \(quotaDetail(for: request))"
        )
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

public struct IncrementalChannelUploadsResult: Sendable {
    public let videos: [DiscoveredVideo]
    public let pagesFetched: Int
    public let hitKnownVideo: Bool
    public let uploadsPlaylistIdFound: Bool
}

public enum ChannelSearchOrder: String, Sendable {
    case date
    case viewCount
}

public struct PlaylistVideoItem: Sendable {
    public let playlistItemId: String?
    public let videoId: String
    public let title: String?
    public let channelId: String?
    public let channelTitle: String?
    public let position: Int
}

struct PlaylistItemsPage: Sendable {
    let nextPageToken: String?
    let items: [PlaylistVideoItem]
}

struct PlaylistInsertRequest: Encodable {
    let snippet: Snippet

    struct Snippet: Encodable {
        let playlistId: String
        let resourceId: ResourceID
    }

    struct ResourceID: Encodable {
        let kind: String
        let videoId: String
    }
}

// MARK: - API Response Types

struct YouTubeResponse: Decodable {
    let items: [YouTubeVideoItem]
}

struct YouTubeVideoItem: Decodable {
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

struct ChannelResponse: Decodable {
    let items: [ChannelItem]
}

struct ChannelItem: Decodable {
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

struct ChannelDetailResponse: Decodable {
    let items: [ChannelDetailItem]
}

struct ChannelUploadsResponse: Decodable {
    let items: [ChannelUploadsItem]
}

struct ChannelUploadsItem: Decodable {
    let contentDetails: ChannelUploadsContentDetails?
}

struct ChannelUploadsContentDetails: Decodable {
    let relatedPlaylists: ChannelRelatedPlaylists?
}

struct ChannelRelatedPlaylists: Decodable {
    let uploads: String?
}

struct SearchResponse: Decodable {
    let items: [SearchItem]
}

struct SearchItem: Decodable {
    let id: SearchItemID
    let snippet: SearchSnippet
}

struct SearchItemID: Decodable {
    let videoId: String?
}

struct SearchSnippet: Decodable {
    let publishedAt: String?
    let channelId: String?
    let channelTitle: String?
    let title: String?
}

struct PlaylistItemsResponse: Decodable {
    let nextPageToken: String?
    let items: [PlaylistItemsResponseItem]
}

struct PlaylistItemsResponseItem: Decodable {
    let id: String?
    let snippet: PlaylistItemsSnippet
}

struct PlaylistItemsSnippet: Decodable {
    let title: String?
    let channelId: String?
    let channelTitle: String?
    let videoOwnerChannelId: String?
    let videoOwnerChannelTitle: String?
    let position: Int?
    let resourceId: PlaylistResourceID
}

struct PlaylistResourceID: Decodable {
    let videoId: String?
}

struct ChannelDetailItem: Decodable {
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
    case noOAuthToken
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .noApiKey:
            return "No YouTube API key found. Set YOUTUBE_API_KEY or GOOGLE_API_KEY env var, or write key to ~/.config/youtube/api-key"
        case .noOAuthToken:
            return "YouTube write access is not available. Reconnect YouTube so the app has playlist write permission."
        case .invalidResponse:
            return "Invalid response from YouTube API"
        case .apiError(let code, let message):
            return "YouTube API error (\(code)): \(Self.compactMessage(from: message))"
        }
    }

    public var isQuotaExceeded: Bool {
        guard case .apiError(let code, let message) = self else { return false }
        guard code == 403 else { return false }
        let compact = Self.compactMessage(from: message).lowercased()
        return compact.contains("quota") || compact.contains("daily limit") || compact.contains("exceeded")
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
