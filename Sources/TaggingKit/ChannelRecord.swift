import Foundation

/// A YouTube channel with locally cached data.
public struct ChannelRecord: Sendable, Identifiable {
    public let channelId: String
    public let name: String
    public let handle: String?
    public let channelUrl: String?
    public let iconUrl: String?
    public let iconData: Data?
    public let subscriberCount: String?
    public let description: String?
    public let videoCountTotal: Int?
    public let fetchedAt: String?
    public let iconFetchedAt: String?

    public var id: String { channelId }

    public init(channelId: String, name: String, handle: String? = nil, channelUrl: String? = nil,
                iconUrl: String? = nil, iconData: Data? = nil, subscriberCount: String? = nil,
                description: String? = nil, videoCountTotal: Int? = nil,
                fetchedAt: String? = nil, iconFetchedAt: String? = nil) {
        self.channelId = channelId
        self.name = name
        self.handle = handle
        self.channelUrl = channelUrl
        self.iconUrl = iconUrl
        self.iconData = iconData
        self.subscriberCount = subscriberCount
        self.description = description
        self.videoCountTotal = videoCountTotal
        self.fetchedAt = fetchedAt
        self.iconFetchedAt = iconFetchedAt
    }
}
