import CryptoKit
import Foundation
import Security

public struct YouTubeOAuthClientConfig: Codable, Sendable {
    public let clientId: String
    public let clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }

    public static func installDownloadedClientJSON(from sourceURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        _ = try parseConfigData(data)

        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/youtube/oauth-client.json")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    public static func isAvailable() -> Bool {
        if let clientId = ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_ID"],
           let clientSecret = ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_SECRET"],
           !clientId.isEmpty, !clientSecret.isEmpty {
            return true
        }

        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/youtube/oauth-client.json")
        return FileManager.default.fileExists(atPath: path.path)
    }

    public static func load() throws -> YouTubeOAuthClientConfig {
        if let clientId = ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_ID"],
           let clientSecret = ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_SECRET"],
           !clientId.isEmpty, !clientSecret.isEmpty {
            return YouTubeOAuthClientConfig(clientId: clientId, clientSecret: clientSecret)
        }

        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/youtube/oauth-client.json")
        let data = try Data(contentsOf: path)
        return try parseConfigData(data)
    }

    private static func parseConfigData(_ data: Data) throws -> YouTubeOAuthClientConfig {
        if let direct = try? JSONDecoder().decode(YouTubeOAuthClientConfig.self, from: data) {
            return direct
        }

        let downloaded = try JSONDecoder().decode(GoogleOAuthClientFile.self, from: data)
        if let installed = downloaded.installed {
            return YouTubeOAuthClientConfig(clientId: installed.clientId, clientSecret: installed.clientSecret)
        }
        if let web = downloaded.web {
            return YouTubeOAuthClientConfig(clientId: web.clientId, clientSecret: web.clientSecret)
        }

        throw YouTubeOAuthError.missingClientConfig
    }
}

public struct YouTubeOAuthTokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let scope: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, tokenType: String, scope: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-60) <= Date()
    }

    public func includesScope(_ requiredScope: String) -> Bool {
        guard let scope else { return false }
        let grantedScopes = Set(scope.split(separator: " ").map(String.init))
        return grantedScopes.contains(requiredScope)
    }
}

public struct YouTubeOAuthAuthorizationRequest: Sendable {
    public let url: URL
    public let state: String
    public let redirectURI: String
    public let codeVerifier: String
}

public enum YouTubeOAuthError: Error, LocalizedError {
    case missingClientConfig
    case missingRefreshToken
    case invalidResponse
    case tokenExchangeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientConfig:
            return "Missing Google OAuth client config. Set GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET or create ~/.config/youtube/oauth-client.json"
        case .missingRefreshToken:
            return "No refresh token is stored yet."
        case .invalidResponse:
            return "Invalid OAuth response."
        case .tokenExchangeFailed(let message):
            return "OAuth token exchange failed: \(message)"
        }
    }
}

public struct YouTubeOAuthTokenStore: Sendable {
    private static let service = "youtube-oauth-tokens"
    private static let account = "default"

    public init() {}

    public func load() -> YouTubeOAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(YouTubeOAuthTokens.self, from: data)
    }

    public func save(_ tokens: YouTubeOAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]

        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        if status == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        } else {
            var query = baseQuery
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public struct YouTubeOAuthService: Sendable {
    private let config: YouTubeOAuthClientConfig
    private let tokenStore: YouTubeOAuthTokenStore
    private let session: URLSession
    public static let readOnlyScope = "https://www.googleapis.com/auth/youtube.readonly"
    public static let writeScope = "https://www.googleapis.com/auth/youtube"
    public static let defaultScope = writeScope

    public init(
        config: YouTubeOAuthClientConfig,
        tokenStore: YouTubeOAuthTokenStore = YouTubeOAuthTokenStore(),
        session: URLSession = .shared
    ) {
        self.config = config
        self.tokenStore = tokenStore
        self.session = session
    }

    public func authorizationURL(
        redirectURI: String,
        state: String = UUID().uuidString,
        scope: String = defaultScope
    ) -> URL {
        authorizationRequest(redirectURI: redirectURI, state: state, scope: scope).url
    }

    public func authorizationRequest(
        redirectURI: String,
        state: String = UUID().uuidString,
        scope: String = defaultScope
    ) -> YouTubeOAuthAuthorizationRequest {
        let codeVerifier = Self.makeCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return YouTubeOAuthAuthorizationRequest(
            url: components.url!,
            state: state,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier
        )
    }

    public func exchangeCode(code: String, redirectURI: String, codeVerifier: String? = nil) async throws -> YouTubeOAuthTokens {
        var bodyItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "client_secret", value: config.clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        if let codeVerifier {
            bodyItems.append(URLQueryItem(name: "code_verifier", value: codeVerifier))
        }
        let tokens = try await performTokenRequest(bodyItems: bodyItems)
        try tokenStore.save(tokens)
        return tokens
    }

    public func refreshIfNeeded(force: Bool = false) async throws -> YouTubeOAuthTokens? {
        guard let existing = tokenStore.load() else { return nil }
        if !force && !existing.isExpired {
            return existing
        }
        guard let refreshToken = existing.refreshToken else {
            throw YouTubeOAuthError.missingRefreshToken
        }

        let bodyItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "client_secret", value: config.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        let refreshed = try await performTokenRequest(
            bodyItems: bodyItems,
            fallbackRefreshToken: refreshToken,
            fallbackScope: existing.scope
        )
        try tokenStore.save(refreshed)
        return refreshed
    }

    public func storedTokens() -> YouTubeOAuthTokens? {
        tokenStore.load()
    }

    private static func makeCodeVerifier() -> String {
        let charset = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<96).map { _ in charset.randomElement(using: &generator)! })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func performTokenRequest(
        bodyItems: [URLQueryItem],
        fallbackRefreshToken: String? = nil,
        fallbackScope: String? = nil
    ) async throws -> YouTubeOAuthTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyString = bodyItems.map { item in
            let value = item.value ?? ""
            return "\(item.name)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
        }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeOAuthError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw YouTubeOAuthError.tokenExchangeFailed(body)
        }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiresAt = payload.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return YouTubeOAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? fallbackRefreshToken,
            tokenType: payload.tokenType,
            scope: payload.scope ?? fallbackScope,
            expiresAt: expiresAt
        )
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?
    let refreshToken: String?
    let scope: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

private struct GoogleOAuthClientFile: Decodable {
    let installed: GoogleOAuthClientSection?
    let web: GoogleOAuthClientSection?
}

private struct GoogleOAuthClientSection: Decodable {
    let clientId: String
    let clientSecret: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }
}
