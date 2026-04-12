import Foundation

extension YouTubeClient {
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
                    let backoff = min(60, 2 * consecutiveErrors)
                    print("  ⚠ Rate limited on batch \(index + 1). Waiting \(backoff)s...")
                    try? await Task.sleep(for: .seconds(backoff))

                    if consecutiveErrors >= 3 {
                        print("  ✘ 3 consecutive failures. Stopping — got \(results.count) videos. Re-run to continue.")
                        break
                    }

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
                    results.append(ChannelRecord(
                        channelId: item.id,
                        name: item.snippet?.title ?? item.id,
                        handle: item.snippet?.customUrl,
                        channelUrl: "https://www.youtube.com/channel/\(item.id)",
                        iconUrl: item.snippet?.thumbnails?.defaultThumbnail?.url,
                        subscriberCount: item.statistics?.subscriberCount,
                        description: item.snippet?.description,
                        videoCountTotal: item.statistics?.videoCount.flatMap { Int($0) },
                        fetchedAt: now
                    ))
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

    public func downloadChannelIcon(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw YouTubeError.invalidResponse
        }
        return data
    }

    public func fetchRecentChannelUploads(
        channelId: String,
        maxResults: Int = 8
    ) async throws -> [DiscoveredVideo] {
        guard let uploadsPlaylistId = try await fetchUploadsPlaylistId(channelId: channelId) else {
            return []
        }

        let items = try await fetchPlaylistItems(
            playlistId: uploadsPlaylistId,
            maxResults: maxResults,
            authorization: .apiKeyOnly
        )

        let metadataById = try await Dictionary(
            uniqueKeysWithValues: fetchVideoMetadata(ids: items.map(\.videoId)).map { ($0.videoId, $0) }
        )

        return items.compactMap { item in
            let metadata = metadataById[item.videoId]
            return DiscoveredVideo(
                videoId: item.videoId,
                title: item.title ?? "Untitled",
                channelId: item.channelId ?? metadata?.channelId,
                channelTitle: item.channelTitle ?? metadata?.channelTitle,
                publishedAt: metadata?.formattedDate,
                duration: metadata?.formattedDuration,
                viewCount: metadata?.formattedViewCount,
                sourceOrder: .date
            )
        }
    }

    public func fetchIncrementalChannelUploads(
        channelId: String,
        knownVideoIDs: Set<String>,
        maxNewResults: Int = 24,
        maxPages: Int = 4
    ) async throws -> IncrementalChannelUploadsResult {
        guard let uploadsPlaylistId = try await fetchUploadsPlaylistId(channelId: channelId) else {
            return IncrementalChannelUploadsResult(videos: [], pagesFetched: 0, hitKnownVideo: false, uploadsPlaylistIdFound: false)
        }

        var collectedItems: [PlaylistVideoItem] = []
        var nextPageToken: String?
        var hitKnownVideo = false
        var pagesFetched = 0

        repeat {
            let page = try await fetchPlaylistItemsPage(
                playlistId: uploadsPlaylistId,
                maxResults: min(50, maxNewResults),
                pageToken: nextPageToken,
                authorization: .apiKeyOnly
            )
            pagesFetched += 1

            for item in page.items {
                if knownVideoIDs.contains(item.videoId) {
                    hitKnownVideo = true
                    break
                }
                collectedItems.append(item)
                if collectedItems.count >= maxNewResults {
                    break
                }
            }

            nextPageToken = page.nextPageToken
        } while nextPageToken != nil && !hitKnownVideo && collectedItems.count < maxNewResults && pagesFetched < maxPages

        guard !collectedItems.isEmpty else {
            return IncrementalChannelUploadsResult(
                videos: [],
                pagesFetched: pagesFetched,
                hitKnownVideo: hitKnownVideo,
                uploadsPlaylistIdFound: true
            )
        }

        let metadataById = try await Dictionary(
            uniqueKeysWithValues: fetchVideoMetadata(ids: collectedItems.map(\.videoId)).map { ($0.videoId, $0) }
        )

        let videos = collectedItems.compactMap { item in
            let metadata = metadataById[item.videoId]
            return DiscoveredVideo(
                videoId: item.videoId,
                title: item.title ?? "Untitled",
                channelId: item.channelId ?? metadata?.channelId,
                channelTitle: item.channelTitle ?? metadata?.channelTitle,
                publishedAt: metadata?.formattedDate,
                duration: metadata?.formattedDuration,
                viewCount: metadata?.formattedViewCount,
                sourceOrder: .date
            )
        }

        return IncrementalChannelUploadsResult(
            videos: videos,
            pagesFetched: pagesFetched,
            hitKnownVideo: hitKnownVideo,
            uploadsPlaylistIdFound: true
        )
    }

    public func fetchPlaylistItems(playlistId: String) async throws -> [PlaylistVideoItem] {
        try await fetchPlaylistItems(
            playlistId: playlistId,
            maxResults: nil,
            authorization: .bearerIfAvailable
        )
    }

    func fetchPlaylistItems(
        playlistId: String,
        maxResults: Int?,
        authorization: AuthorizationMode
    ) async throws -> [PlaylistVideoItem] {
        var results: [PlaylistVideoItem] = []
        var nextPageToken: String?
        let cappedMaxResults = maxResults.map { max(1, min($0, 50)) }
        let remainingLimit = { maxResults.map { max($0 - results.count, 0) } }

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            let pageSize = min(50, cappedMaxResults ?? 50, remainingLimit() ?? 50)
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "playlistId", value: playlistId),
                URLQueryItem(name: "maxResults", value: String(pageSize)),
                URLQueryItem(name: "key", value: apiKey)
            ]
            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }
            components.queryItems = queryItems

            let (data, response) = try await requestData(from: components.url!, authorization: authorization)
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
                    playlistItemId: item.id,
                    videoId: videoId,
                    title: item.snippet.title,
                    channelId: item.snippet.videoOwnerChannelId ?? item.snippet.channelId,
                    channelTitle: item.snippet.videoOwnerChannelTitle ?? item.snippet.channelTitle,
                    position: item.snippet.position ?? results.count
                ))
            }
            nextPageToken = decoded.nextPageToken
        } while nextPageToken != nil && (remainingLimit() ?? 1) > 0

        return results
    }

    private func fetchPlaylistItemsPage(
        playlistId: String,
        maxResults: Int,
        pageToken: String?,
        authorization: AuthorizationMode
    ) async throws -> PlaylistItemsPage {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "playlistId", value: playlistId),
            URLQueryItem(name: "maxResults", value: String(max(1, min(maxResults, 50)))),
            URLQueryItem(name: "key", value: apiKey)
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems

        let (data, response) = try await requestData(from: components.url!, authorization: authorization)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw YouTubeError.apiError(statusCode: http.statusCode, message: body)
        }

        let decoded = try JSONDecoder().decode(PlaylistItemsResponse.self, from: data)
        let items = decoded.items.compactMap { item -> PlaylistVideoItem? in
            guard let videoId = item.snippet.resourceId.videoId else { return nil }
            return PlaylistVideoItem(
                playlistItemId: item.id,
                videoId: videoId,
                title: item.snippet.title,
                channelId: item.snippet.videoOwnerChannelId ?? item.snippet.channelId,
                channelTitle: item.snippet.videoOwnerChannelTitle ?? item.snippet.channelTitle,
                position: item.snippet.position ?? 0
            )
        }
        return PlaylistItemsPage(nextPageToken: decoded.nextPageToken, items: items)
    }

    private func fetchUploadsPlaylistId(channelId: String) async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "id", value: channelId),
            URLQueryItem(name: "maxResults", value: "1"),
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

        let decoded = try JSONDecoder().decode(ChannelUploadsResponse.self, from: data)
        return decoded.items.first?.contentDetails?.relatedPlaylists?.uploads
    }
}
