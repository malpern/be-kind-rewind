import Foundation

/// Identifies a deep-link destination inside the detail-column NavigationStack.
///
/// Phase 1 only carries the creator detail route. Phase 4 will add `.topic(topicId:)`
/// and `.libraryInsights` once the corresponding views exist. Hosting this enum in a
/// dedicated file lets it be referenced from `OrganizerStore` (which exposes the
/// navigation path) without dragging in any SwiftUI dependencies.
enum DetailRoute: Hashable {
    case creator(channelId: String)
}
