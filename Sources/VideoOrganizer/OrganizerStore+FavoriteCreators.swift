import Foundation
import TaggingKit

extension OrganizerStore {
    /// Reload the in-memory favorite creators cache from the database.
    /// Called from init and after every favorite/unfavorite action.
    func refreshFavoriteCreators() {
        do {
            favoriteCreators = try store.favoriteChannelsList()
        } catch {
            AppLogger.app.error("Failed to load favorite creators: \(error.localizedDescription, privacy: .public)")
            favoriteCreators = []
        }
    }

    /// Pin a creator as a favorite. Idempotent (insert-or-replace at the storage level).
    /// Used by the Pin toolbar action on the creator detail page.
    func favoriteCreator(channelId: String, channelName: String, iconUrl: String? = nil) {
        do {
            try store.favoriteChannel(
                channelId: channelId,
                channelName: channelName,
                iconUrl: iconUrl
            )
            refreshFavoriteCreators()
            AppLogger.app.info("Favorited creator \(channelName, privacy: .public) (\(channelId, privacy: .public))")
        } catch {
            AppLogger.app.error("Failed to favorite creator \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove a creator from favorites. No-op if not currently favorited.
    func unfavoriteCreator(channelId: String) {
        do {
            try store.unfavoriteChannel(channelId: channelId)
            refreshFavoriteCreators()
            AppLogger.app.info("Unfavorited creator \(channelId, privacy: .public)")
        } catch {
            AppLogger.app.error("Failed to unfavorite creator \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Toggle the favorite state of a creator. Returns the new state (true if now favorited).
    @discardableResult
    func toggleFavoriteCreator(channelId: String, channelName: String, iconUrl: String? = nil) -> Bool {
        if isCreatorFavorited(channelId) {
            unfavoriteCreator(channelId: channelId)
            return false
        } else {
            favoriteCreator(channelId: channelId, channelName: channelName, iconUrl: iconUrl)
            return true
        }
    }

    /// Fast in-memory membership check against the cached favorites list.
    func isCreatorFavorited(_ channelId: String) -> Bool {
        favoriteCreators.contains(where: { $0.channelId == channelId })
    }

    /// Push the creator detail page onto the detail-column NavigationStack. Idempotent —
    /// if the topmost route is already this creator, the call is a no-op so repeated
    /// clicks don't stack the same page.
    func openCreatorDetail(channelId: String) {
        if case .creator(let topId) = detailPath.last, topId == channelId {
            return
        }
        detailPath.append(.creator(channelId: channelId))
    }

    /// Clear the entire detail-column navigation path back to the topic grid root.
    func popToRootDetail() {
        detailPath.removeAll()
    }

    /// Save free-text notes for a creator. If the creator isn't yet favorited, this
    /// implicitly favorites them — notes only persist on rows in favorite_channels.
    /// Pass nil or empty to clear notes (the row stays favorited).
    func setNotesForCreator(channelId: String, channelName: String, iconUrl: String? = nil, notes: String?) {
        do {
            // Ensure the row exists.
            if !isCreatorFavorited(channelId) {
                try store.favoriteChannel(
                    channelId: channelId,
                    channelName: channelName,
                    iconUrl: iconUrl
                )
            }
            try store.updateFavoriteChannelNotes(channelId: channelId, notes: notes?.isEmpty == true ? nil : notes)
            refreshFavoriteCreators()
        } catch {
            AppLogger.app.error("Failed to update notes for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
