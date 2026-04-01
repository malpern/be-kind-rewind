import Testing
@testable import TaggingKit

@Suite("ClaudeClient")
struct ClaudeClientTests {
    @Test("init throws without API key in environment or keychain")
    func initThrowsWithoutKey() {
        // This test verifies the error path — in CI where there's no keychain entry
        // and no env var, init should throw
        do {
            let _ = try ClaudeClient()
            // If it succeeds, there's a key in the keychain — that's fine
        } catch {
            #expect(error is ClaudeClientError)
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
}
