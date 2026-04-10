import Foundation
import Testing
@testable import VideoOrganizer

@Suite("FavoriteCreators — OrganizerStore actions")
struct FavoriteCreatorsTests {

    @MainActor
    @Test("favoriteCreator inserts a record and updates the in-memory cache")
    func favoriteAddsToCache() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            #expect(store.favoriteCreators.isEmpty)
            #expect(store.isCreatorFavorited("chan-alpha") == false)

            store.favoriteCreator(
                channelId: "chan-alpha",
                channelName: "Alpha Channel",
                iconUrl: "https://example.com/a.png"
            )

            #expect(store.favoriteCreators.count == 1)
            #expect(store.favoriteCreators[0].channelId == "chan-alpha")
            #expect(store.favoriteCreators[0].iconUrl == "https://example.com/a.png")
            #expect(store.isCreatorFavorited("chan-alpha") == true)
        }
    }

    @MainActor
    @Test("unfavoriteCreator removes the record and updates the cache")
    func unfavoriteRemovesFromCache() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            store.favoriteCreator(channelId: "chan-alpha", channelName: "Alpha Channel")
            #expect(store.isCreatorFavorited("chan-alpha") == true)

            store.unfavoriteCreator(channelId: "chan-alpha")
            #expect(store.isCreatorFavorited("chan-alpha") == false)
            #expect(store.favoriteCreators.isEmpty)
        }
    }

    @MainActor
    @Test("toggleFavoriteCreator flips state and returns the new value")
    func toggleFlipsAndReturnsState() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            let firstResult = store.toggleFavoriteCreator(
                channelId: "chan-alpha",
                channelName: "Alpha Channel"
            )
            #expect(firstResult == true)
            #expect(store.isCreatorFavorited("chan-alpha") == true)

            let secondResult = store.toggleFavoriteCreator(
                channelId: "chan-alpha",
                channelName: "Alpha Channel"
            )
            #expect(secondResult == false)
            #expect(store.isCreatorFavorited("chan-alpha") == false)
        }
    }

    @MainActor
    @Test("favoriteCreators cache survives a fresh store load")
    func favoritesPersistAcrossLoad() throws {
        try withFileBackedOrganizerFixture { fixture in
            do {
                let store1 = try fixture.makeOrganizerStore()
                store1.favoriteCreator(channelId: "chan-alpha", channelName: "Alpha Channel")
                #expect(store1.isCreatorFavorited("chan-alpha") == true)
            }

            // Re-open the same database file and verify the favorite is still there.
            let store2 = try fixture.makeOrganizerStore()
            #expect(store2.isCreatorFavorited("chan-alpha") == true)
            #expect(store2.favoriteCreators.count == 1)
        }
    }

    @MainActor
    @Test("favoriting an already-favorited creator is idempotent")
    func favoriteIsIdempotent() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            store.favoriteCreator(channelId: "chan-alpha", channelName: "Alpha Channel")
            store.favoriteCreator(channelId: "chan-alpha", channelName: "Alpha Channel")

            #expect(store.favoriteCreators.count == 1)
        }
    }

    @MainActor
    @Test("multiple distinct creators can be favorited")
    func multipleDistinctFavorites() throws {
        try withFileBackedOrganizerFixture { fixture in
            let store = try fixture.makeOrganizerStore()

            store.favoriteCreator(channelId: "chan-alpha", channelName: "Alpha Channel")
            store.favoriteCreator(channelId: "chan-beta", channelName: "Beta Channel")

            #expect(store.favoriteCreators.count == 2)
            #expect(store.isCreatorFavorited("chan-alpha") == true)
            #expect(store.isCreatorFavorited("chan-beta") == true)
            #expect(store.isCreatorFavorited("chan-gamma") == false)
        }
    }
}
