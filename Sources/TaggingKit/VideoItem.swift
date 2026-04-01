import Foundation

/// A video loaded from an inventory snapshot.
public struct VideoItem: Codable, Identifiable, Sendable {
    public let sourceIndex: Int
    public let title: String?
    public let videoUrl: String?
    public let videoId: String?
    public let channelName: String?
    public let metadataText: String?
    public let unavailableKind: String

    public init(sourceIndex: Int, title: String?, videoUrl: String?, videoId: String?,
                channelName: String?, metadataText: String?, unavailableKind: String) {
        self.sourceIndex = sourceIndex
        self.title = title
        self.videoUrl = videoUrl
        self.videoId = videoId
        self.channelName = channelName
        self.metadataText = metadataText
        self.unavailableKind = unavailableKind
    }

    public var id: String {
        videoId ?? "index-\(sourceIndex)"
    }

    /// The best available text for embedding — title with optional channel context.
    public var embeddingText: String? {
        guard let title, !title.isEmpty else { return nil }
        if let channel = channelName, !channel.isEmpty {
            return "\(title) — \(channel)"
        }
        return title
    }
}
