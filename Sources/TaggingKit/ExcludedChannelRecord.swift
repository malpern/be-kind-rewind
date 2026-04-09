import Foundation

public struct ExcludedChannelRecord: Sendable, Identifiable, Hashable {
    public let channelId: String
    public let channelName: String
    public let iconUrl: String?
    public let excludedAt: String
    public let reason: String?

    public var id: String { channelId }

    public init(
        channelId: String,
        channelName: String,
        iconUrl: String? = nil,
        excludedAt: String,
        reason: String? = nil
    ) {
        self.channelId = channelId
        self.channelName = channelName
        self.iconUrl = iconUrl
        self.excludedAt = excludedAt
        self.reason = reason
    }
}
