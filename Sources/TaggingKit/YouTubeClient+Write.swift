import Foundation

extension YouTubeClient {
    public func removeVideoFromPlaylist(videoId: String, playlistId: String) async throws {
        let accessToken = try await validWriteAccessToken()
        let items = try await fetchPlaylistItems(
            playlistId: playlistId,
            maxResults: nil,
            authorization: .bearerIfAvailable
        )

        let matchingIds = items
            .filter { $0.videoId == videoId }
            .compactMap(\.playlistItemId)

        guard !matchingIds.isEmpty else { return }

        for playlistItemId in matchingIds {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            components.queryItems = [
                URLQueryItem(name: "id", value: playlistItemId)
            ]

            var request = URLRequest(url: components.url!)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            await recordQuotaEvent(for: request, response: response)
            guard let http = response as? HTTPURLResponse else {
                throw YouTubeError.invalidResponse
            }
            guard http.statusCode == 204 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw YouTubeError.apiError(statusCode: http.statusCode, message: body)
            }
        }
    }

    public func addVideoToPlaylist(videoId: String, playlistId: String) async throws {
        let accessToken = try await validWriteAccessToken()

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = PlaylistInsertRequest(
            snippet: .init(
                playlistId: playlistId,
                resourceId: .init(kind: "youtube#video", videoId: videoId)
            )
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        await recordQuotaEvent(for: request, response: response)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw YouTubeError.apiError(statusCode: http.statusCode, message: body)
        }
    }
}
