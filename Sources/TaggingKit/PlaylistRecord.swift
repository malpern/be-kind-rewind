import Foundation

public struct PlaylistRecord: Sendable, Identifiable {
    public let playlistId: String
    public let title: String
    public let visibility: String?
    public let videoCount: Int?
    public let source: String?
    public let fetchedAt: String?

    public var id: String { playlistId }

    public init(
        playlistId: String,
        title: String,
        visibility: String? = nil,
        videoCount: Int? = nil,
        source: String? = nil,
        fetchedAt: String? = nil
    ) {
        self.playlistId = playlistId
        self.title = title
        self.visibility = visibility
        self.videoCount = videoCount
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

public struct PlaylistMembershipRecord: Sendable {
    public let playlistId: String
    public let videoId: String
    public let position: Int?
    public let verifiedAt: String?

    public init(playlistId: String, videoId: String, position: Int? = nil, verifiedAt: String? = nil) {
        self.playlistId = playlistId
        self.videoId = videoId
        self.position = position
        self.verifiedAt = verifiedAt
    }
}
