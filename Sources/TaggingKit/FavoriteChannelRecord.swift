import Foundation

/// Persistent record of a "pinned" or favorite creator. Mirrors `ExcludedChannelRecord`
/// in shape, but represents the user's positive preference rather than a hide signal.
///
/// Used by the creator detail page (Phase 1) to surface a `Pin` toolbar action and to
/// drive favorite-creator boosting in Watch refresh ranking (Phase 3). The optional
/// `notes` field is added at table-creation time even though it is not surfaced in
/// Phase 1 — making the column available cheaply now avoids a schema migration when
/// notes ship in Phase 3.
public struct FavoriteChannelRecord: Sendable, Identifiable, Hashable {
    public let channelId: String
    public let channelName: String
    public let iconUrl: String?
    public let favoritedAt: String
    public let notes: String?

    public var id: String { channelId }

    public init(
        channelId: String,
        channelName: String,
        iconUrl: String? = nil,
        favoritedAt: String,
        notes: String? = nil
    ) {
        self.channelId = channelId
        self.channelName = channelName
        self.iconUrl = iconUrl
        self.favoritedAt = favoritedAt
        self.notes = notes
    }
}
