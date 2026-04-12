import Foundation

extension YouTubeClient {
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
            return discoveredVideo(from: item, metadata: metadata, sourceOrder: order)
        }
    }

    public func searchVideos(
        query: String,
        maxResults: Int = 8,
        publishedAfterDays: Int? = nil
    ) async throws -> [DiscoveredVideo] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "order", value: ChannelSearchOrder.date.rawValue),
            URLQueryItem(name: "maxResults", value: String(max(1, min(maxResults, 25)))),
            URLQueryItem(name: "key", value: apiKey)
        ]
        if let publishedAfterDays, publishedAfterDays > 0 {
            let cutoff = Calendar.current.date(byAdding: .day, value: -publishedAfterDays, to: Date()) ?? Date()
            queryItems.append(URLQueryItem(name: "publishedAfter", value: ISO8601DateFormatter().string(from: cutoff)))
        }
        components.queryItems = queryItems

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
            return discoveredVideo(from: item, metadata: metadata, sourceOrder: .date)
        }
    }

    private func discoveredVideo(
        from item: SearchItem,
        metadata: VideoMetadata?,
        sourceOrder: ChannelSearchOrder
    ) -> DiscoveredVideo? {
        guard let videoId = item.id.videoId else { return nil }
        return DiscoveredVideo(
            videoId: videoId,
            title: item.snippet.title ?? "Untitled",
            channelId: item.snippet.channelId ?? metadata?.channelId,
            channelTitle: item.snippet.channelTitle ?? metadata?.channelTitle,
            publishedAt: metadata?.formattedDate ?? VideoMetadata(
                videoId: videoId,
                viewCount: nil,
                publishedAt: item.snippet.publishedAt,
                duration: nil,
                channelId: nil,
                channelTitle: nil
            ).formattedDate,
            duration: metadata?.formattedDuration,
            viewCount: metadata?.formattedViewCount,
            sourceOrder: sourceOrder
        )
    }
}
