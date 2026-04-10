import Foundation

/// Persistent representation of a single LLM-generated theme cluster for a creator.
/// Mirrors `CreatorThemeClassifier.ThemeCluster` but adds the channel-id key and the
/// classification metadata used for cache invalidation.
public struct CreatorThemeRecord: Sendable, Equatable {
    public let channelId: String
    public let label: String
    public let description: String?
    public let order: Int
    public let videoIds: [String]
    public let isSeries: Bool
    public let orderingSignal: String?
    public let classifiedAt: String
    public let classifiedVideoCount: Int

    public init(
        channelId: String,
        label: String,
        description: String?,
        order: Int,
        videoIds: [String],
        isSeries: Bool,
        orderingSignal: String?,
        classifiedAt: String,
        classifiedVideoCount: Int
    ) {
        self.channelId = channelId
        self.label = label
        self.description = description
        self.order = order
        self.videoIds = videoIds
        self.isSeries = isSeries
        self.orderingSignal = orderingSignal
        self.classifiedAt = classifiedAt
        self.classifiedVideoCount = classifiedVideoCount
    }
}

/// Persistent representation of a creator's LLM-generated "About" paragraph.
public struct CreatorAboutRecord: Sendable, Equatable {
    public let channelId: String
    public let summary: String
    public let generatedAt: String
    public let sourceVideoCount: Int

    public init(
        channelId: String,
        summary: String,
        generatedAt: String,
        sourceVideoCount: Int
    ) {
        self.channelId = channelId
        self.summary = summary
        self.generatedAt = generatedAt
        self.sourceVideoCount = sourceVideoCount
    }
}
