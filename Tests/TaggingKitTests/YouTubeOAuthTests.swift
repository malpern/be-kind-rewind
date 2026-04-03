import Foundation
import Testing
@testable import TaggingKit

private func withEnvironment<T>(
    _ values: [String: String?],
    body: () throws -> T
) rethrows -> T {
    let original = Dictionary(uniqueKeysWithValues: values.keys.map { key in
        (key, ProcessInfo.processInfo.environment[key])
    })

    for (key, value) in values {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    defer {
        for (key, value) in original {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    return try body()
}

@Suite("YouTubeOAuth", .serialized)
struct YouTubeOAuthTests {
    @Test("loads OAuth client config from environment")
    func loadClientConfigFromEnvironment() throws {
        let config = try withEnvironment([
            "GOOGLE_OAUTH_CLIENT_ID": "client-id",
            "GOOGLE_OAUTH_CLIENT_SECRET": "client-secret"
        ]) {
            try YouTubeOAuthClientConfig.load()
        }

        #expect(config.clientId == "client-id")
        #expect(config.clientSecret == "client-secret")
    }

    @Test("token expiry uses a one-minute safety window")
    func tokenExpiry() {
        let valid = YouTubeOAuthTokens(
            accessToken: "token",
            refreshToken: "refresh",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: Date.now.addingTimeInterval(300)
        )
        let nearlyExpired = YouTubeOAuthTokens(
            accessToken: "token",
            refreshToken: "refresh",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: Date.now.addingTimeInterval(30)
        )
        let noExpiry = YouTubeOAuthTokens(
            accessToken: "token",
            refreshToken: nil,
            tokenType: "Bearer",
            scope: nil,
            expiresAt: nil
        )

        #expect(valid.isExpired == false)
        #expect(nearlyExpired.isExpired == true)
        #expect(noExpiry.isExpired == false)
    }

    @Test("authorization request includes PKCE, state, and requested scope")
    func authorizationRequest() {
        let config = YouTubeOAuthClientConfig(clientId: "client-id", clientSecret: "client-secret")
        let service = YouTubeOAuthService(config: config)

        let request = service.authorizationRequest(
            redirectURI: "http://localhost/callback",
            state: "fixed-state",
            scope: "scope-a scope-b"
        )

        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let queryItems = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components?.host == "accounts.google.com")
        #expect(queryItems["client_id"] == "client-id")
        #expect(queryItems["redirect_uri"] == "http://localhost/callback")
        #expect(queryItems["response_type"] == "code")
        #expect(queryItems["scope"] == "scope-a scope-b")
        #expect(queryItems["state"] == "fixed-state")
        #expect(queryItems["code_challenge_method"] == "S256")
        #expect(queryItems["code_challenge"]?.isEmpty == false)
        #expect(request.state == "fixed-state")
        #expect(request.redirectURI == "http://localhost/callback")
        #expect(request.codeVerifier.count == 96)
    }

    @Test("oauth error descriptions are stable")
    func errorDescriptions() {
        #expect(YouTubeOAuthError.missingClientConfig.errorDescription == "Missing Google OAuth client config. Set GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET or create ~/.config/youtube/oauth-client.json")
        #expect(YouTubeOAuthError.missingRefreshToken.errorDescription == "No refresh token is stored yet.")
        #expect(YouTubeOAuthError.invalidResponse.errorDescription == "Invalid OAuth response.")
        #expect(YouTubeOAuthError.tokenExchangeFailed("denied").errorDescription == "OAuth token exchange failed: denied")
    }
}
