import Foundation
import Security
import Testing
@testable import TaggingKit

@Suite("YouTubeOAuthTokenStore")
struct YouTubeOAuthTokenStoreTests {
    @Test("keychain status helper is a no-op for success")
    func successStatus() throws {
        try YouTubeOAuthTokenStore.checkKeychainStatus(errSecSuccess, operation: "save OAuth tokens")
    }

    @Test("keychain status helper throws a user-facing error for failure")
    func failureStatus() {
        #expect(throws: NSError.self) {
            try YouTubeOAuthTokenStore.checkKeychainStatus(errSecAuthFailed, operation: "save OAuth tokens")
        }
    }
}
