import Testing
@testable import TaggingKit

@Suite("ClaudeClient")
struct ClaudeClientTests {
    @Test("init without explicit key either resolves local credentials or throws missing-key")
    func initWithoutExplicitKeyHasExpectedOutcome() {
        do {
            let _ = try ClaudeClient()
        } catch {
            #expect(error is ClaudeClientError)
            if case ClaudeClientError.missingAPIKey = error {
                #expect(Bool(true))
            } else {
                Issue.record("Expected missingAPIKey when ClaudeClient init fails without an explicit key.")
            }
        }
    }

    @Test("init with explicit key succeeds")
    func initWithKey() {
        let client = ClaudeClient(apiKey: "sk-ant-test-key")
        // Just verifying it doesn't crash
        _ = client
    }

    @Test("Model enum has correct raw values")
    func modelIds() {
        #expect(ClaudeClient.Model.haiku.rawValue == "claude-haiku-4-5-20251001")
        #expect(ClaudeClient.Model.sonnet.rawValue == "claude-sonnet-4-6")
    }

    @Test("error descriptions are stable for user-facing failures")
    func errorDescriptions() {
        #expect(ClaudeClientError.missingAPIKey.errorDescription == "ANTHROPIC_API_KEY environment variable is not set.")
        #expect(ClaudeClientError.invalidResponse.errorDescription == "Received an invalid response from the Claude API.")
        #expect(ClaudeClientError.emptyResponse.errorDescription == "Claude returned an empty response.")
        #expect(ClaudeClientError.apiError(status: 401, body: "denied").errorDescription == "Claude API error (HTTP 401): denied")
    }
}
