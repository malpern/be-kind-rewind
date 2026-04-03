import Foundation

public struct TopicCandidate: Sendable, Identifiable {
    public let topicId: Int64
    public let videoId: String
    public let title: String
    public let channelId: String?
    public let channelName: String?
    public let videoUrl: String?
    public let viewCount: String?
    public let publishedAt: String?
    public let duration: String?
    public let channelIconUrl: String?
    public let score: Double
    public let reason: String
    public let state: String
    public let discoveredAt: String?

    public var id: String { "\(topicId)-\(videoId)" }

    public init(
        topicId: Int64,
        videoId: String,
        title: String,
        channelId: String? = nil,
        channelName: String? = nil,
        videoUrl: String? = nil,
        viewCount: String? = nil,
        publishedAt: String? = nil,
        duration: String? = nil,
        channelIconUrl: String? = nil,
        score: Double,
        reason: String,
        state: String = CandidateState.candidate.rawValue,
        discoveredAt: String? = nil
    ) {
        self.topicId = topicId
        self.videoId = videoId
        self.title = title
        self.channelId = channelId
        self.channelName = channelName
        self.videoUrl = videoUrl
        self.viewCount = viewCount
        self.publishedAt = publishedAt
        self.duration = duration
        self.channelIconUrl = channelIconUrl
        self.score = score
        self.reason = reason
        self.state = state
        self.discoveredAt = discoveredAt
    }
}

public struct CandidateSourceRecord: Sendable {
    public let topicId: Int64
    public let videoId: String
    public let sourceKind: String
    public let sourceRef: String

    public init(topicId: Int64, videoId: String, sourceKind: String, sourceRef: String) {
        self.topicId = topicId
        self.videoId = videoId
        self.sourceKind = sourceKind
        self.sourceRef = sourceRef
    }
}

public enum CandidateState: String, Sendable, CaseIterable {
    case candidate
    case researched
    case dismissed
    case watched
}
