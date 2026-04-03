import Foundation

/// Lightweight Claude API client using URLSession. No external SDK needed.
public actor ClaudeClient {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    public enum Model: String, Sendable {
        case haiku = "claude-haiku-4-5-20251001"
        case sonnet = "claude-sonnet-4-6"
    }

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Cached key to avoid repeated keychain prompts
    nonisolated(unsafe) private static var cachedKey: String?

    public init() throws {
        if let cached = Self.cachedKey {
            self.apiKey = cached
            return
        }

        // 1. Config file: ~/.config/anthropic/api-key
        if let key = Self.readFromConfigFile() {
            Self.cachedKey = key
            self.apiKey = key
            return
        }

        // 2. macOS Keychain
        if let key = Self.readFromKeychain() {
            Self.cachedKey = key
            self.apiKey = key
            return
        }

        // 3. Environment variable fallback
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty, key.hasPrefix("sk-ant-") {
            Self.cachedKey = key
            self.apiKey = key
            return
        }

        throw ClaudeClientError.missingAPIKey
    }

    private static func readFromConfigFile() -> String? {
        let paths = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/anthropic/api-key"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anthropic-api-key")
        ]

        for path in paths {
            if let contents = try? String(contentsOf: path, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("sk-ant-") {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "anthropic-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func complete(
        prompt: String,
        system: String? = nil,
        model: Model = .haiku,
        maxTokens: Int = 4096
    ) async throws -> String {
        let messages: [[String: Any]] = [
            ["role": "user", "content": prompt]
        ]

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "messages": messages
        ]

        if let system {
            body["system"] = system
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeClientError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            throw ClaudeClientError.apiError(status: httpResponse.statusCode, body: body)
        }

        let result = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        guard let text = result.content.first?.text else {
            throw ClaudeClientError.emptyResponse
        }

        return text
    }
}

private struct ClaudeResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}

public enum ClaudeClientError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(status: Int, body: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "ANTHROPIC_API_KEY environment variable is not set."
        case .invalidResponse:
            "Received an invalid response from the Claude API."
        case .apiError(let status, let body):
            "Claude API error (HTTP \(status)): \(body.prefix(200))"
        case .emptyResponse:
            "Claude returned an empty response."
        }
    }
}
