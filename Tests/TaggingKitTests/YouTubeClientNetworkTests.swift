import Foundation
import Testing
@testable import TaggingKit

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeMockSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    MockURLProtocol.requestHandler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

@Suite("YouTubeClient Network", .serialized)
struct YouTubeClientNetworkTests {
    @Test("fetchVideoMetadata decodes video metadata response")
    func fetchVideoMetadataDecodesResponse() async throws {
        let session = makeMockSession { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(components.path == "/youtube/v3/videos")
            #expect(queryItems["id"] == "vid-1,vid-2")

            let body = """
            {
              "items": [
                {
                  "id": "vid-1",
                  "snippet": {
                    "publishedAt": "2026-01-02T00:00:00Z",
                    "channelId": "chan-1",
                    "channelTitle": "Channel One"
                  },
                  "contentDetails": { "duration": "PT15M33S" },
                  "statistics": { "viewCount": "1234" }
                }
              ]
            }
            """
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let client = YouTubeClient(apiKey: "yt-key", session: session)
        let metadata = try await client.fetchVideoMetadata(ids: ["vid-1", "vid-2"])

        #expect(metadata.count == 1)
        let item = try #require(metadata.first)
        #expect(item.videoId == "vid-1")
        #expect(item.viewCount == "1234")
        #expect(item.duration == "PT15M33S")
        #expect(item.channelId == "chan-1")
        #expect(item.channelTitle == "Channel One")
    }

    @Test("fetchVideoMetadata surfaces API errors")
    func fetchVideoMetadataReportsApiError() async {
        let session = makeMockSession { request in
            let url = try #require(request.url)
            let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data("quota exceeded".utf8))
        }

        let client = YouTubeClient(apiKey: "yt-key", session: session)

        await #expect(throws: YouTubeError.self) {
            _ = try await client.fetchVideoMetadata(ids: ["vid-1"])
        }
    }

    @Test("fetchChannelThumbnails maps default thumbnail URLs")
    func fetchChannelThumbnailsDecodesResponse() async throws {
        let session = makeMockSession { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.path == "/youtube/v3/channels")

            let body = """
            {
              "items": [
                {
                  "id": "chan-1",
                  "snippet": {
                    "thumbnails": {
                      "default": { "url": "https://example.com/chan-1.jpg" }
                    }
                  }
                }
              ]
            }
            """
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let client = YouTubeClient(apiKey: "yt-key", session: session)
        let thumbnails = try await client.fetchChannelThumbnails(channelIds: ["chan-1"])

        #expect(thumbnails == ["chan-1": "https://example.com/chan-1.jpg"])
    }

    @Test("fetchPlaylistItems paginates and prefers owner channel metadata")
    func fetchPlaylistItemsPaginates() async throws {
        let session = makeMockSession { request in
            let url = try #require(request.url)
            let isSecondPage = url.query?.localizedStandardContains("pageToken=NEXT") == true
            let body = if isSecondPage {
                """
                {
                  "nextPageToken": null,
                  "items": [
                    {
                      "snippet": {
                        "title": "Video Two",
                        "channelId": "fallback-2",
                        "channelTitle": "Fallback Two",
                        "position": 1,
                        "resourceId": { "videoId": "vid-2" }
                      }
                    }
                  ]
                }
                """
            } else {
                """
                {
                  "nextPageToken": "NEXT",
                  "items": [
                    {
                      "snippet": {
                        "title": "Video One",
                        "channelId": "fallback-1",
                        "channelTitle": "Fallback One",
                        "videoOwnerChannelId": "owner-1",
                        "videoOwnerChannelTitle": "Owner One",
                        "position": 0,
                        "resourceId": { "videoId": "vid-1" }
                      }
                    }
                  ]
                }
                """
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let client = YouTubeClient(apiKey: "yt-key", session: session)
        let items = try await client.fetchPlaylistItems(playlistId: "playlist-1")

        #expect(items.map(\.videoId) == ["vid-1", "vid-2"])
        #expect(items[0].channelId == "owner-1")
        #expect(items[0].channelTitle == "Owner One")
        #expect(items[1].channelId == "fallback-2")
        #expect(items[1].position == 1)
    }
}
