import Foundation
import Testing
@testable import TaggingKit
@testable import VideoOrganizer

// MARK: - Mock Token Store

/// In-memory token store for testing. No keychain access.
private struct MockTokenStore: Sendable {
    let tokens: YouTubeOAuthTokens?

    func load() -> YouTubeOAuthTokens? { tokens }
    func save(_ tokens: YouTubeOAuthTokens) throws {}
    func clear() {}
}

// MARK: - Loopback Receiver Parsing Tests

/// Tests for the OAuth callback URL parsing logic. These are the most
/// error-prone paths in the auth flow — malformed callbacks, missing
/// parameters, state mismatches.
@Suite("YouTubeOAuth — Loopback receiver parsing")
struct OAuthLoopbackParsingTests {

    @Test("valid callback with code and state extracts the code")
    func validCallback() {
        let request = "GET /oauth/callback?code=AUTH_CODE_123&state=expected HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\r\n"
        let result = OAuthCallbackParser.parse(request, expectedPath: "/oauth/callback", expectedState: "expected")
        if case .success(let code) = result {
            #expect(code == "AUTH_CODE_123")
        } else {
            Issue.record("Expected success with AUTH_CODE_123")
        }
    }

    @Test("callback with error parameter produces failure")
    func errorCallback() {
        let request = "GET /oauth/callback?error=access_denied&state=expected HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\r\n"
        let result = OAuthCallbackParser.parse(request, expectedPath: "/oauth/callback", expectedState: "expected")
        if case .failure(let error) = result {
            #expect(error.localizedDescription.contains("access_denied"))
        } else {
            Issue.record("Expected failure for error callback")
        }
    }

    @Test("callback with wrong state produces failure")
    func stateMismatch() {
        let request = "GET /oauth/callback?code=AUTH_CODE&state=wrong HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\r\n"
        let result = OAuthCallbackParser.parse(request, expectedPath: "/oauth/callback", expectedState: "expected")
        if case .failure(let error) = result {
            #expect(error.localizedDescription.contains("state"))
        } else {
            Issue.record("Expected failure for state mismatch")
        }
    }

    @Test("callback with missing code produces failure")
    func missingCode() {
        let request = "GET /oauth/callback?state=expected HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\r\n"
        let result = OAuthCallbackParser.parse(request, expectedPath: "/oauth/callback", expectedState: "expected")
        #expect(result.isFailure)
    }

    @Test("completely malformed request produces failure")
    func malformedRequest() {
        let result = OAuthCallbackParser.parse("GARBAGE", expectedPath: "/oauth/callback", expectedState: "x")
        #expect(result.isFailure)
    }

    @Test("empty request produces failure")
    func emptyRequest() {
        let result = OAuthCallbackParser.parse("", expectedPath: "/oauth/callback", expectedState: "x")
        #expect(result.isFailure)
    }

    @Test("wrong path produces failure")
    func wrongPath() {
        let request = "GET /wrong/path?code=AUTH_CODE&state=expected HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\r\n"
        let result = OAuthCallbackParser.parse(request, expectedPath: "/oauth/callback", expectedState: "expected")
        #expect(result.isFailure)
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
