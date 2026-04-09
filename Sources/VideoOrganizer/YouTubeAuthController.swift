import AppKit
import Foundation
import Network
import Observation
import TaggingKit

@MainActor
@Observable
final class YouTubeAuthController {
    private let tokenStore: YouTubeOAuthTokenStore

    private(set) var isBusy = false
    private(set) var isConnected = false
    private(set) var hasWriteAccess = false
    private(set) var statusTitle = "YouTube not connected"
    private(set) var statusDetail = "Authorize YouTube access so the app can verify private playlists and save videos to your playlists."
    private(set) var buttonTitle = "Connect YouTube"
    private(set) var buttonSubtitle = "Open the browser and approve access for private playlist sync"
    private(set) var errorMessage: String?
    private(set) var hasClientConfig = false

    init(tokenStore: YouTubeOAuthTokenStore = YouTubeOAuthTokenStore()) {
        self.tokenStore = tokenStore
        refreshStatus()
    }

    func refreshStatus(clearError: Bool = false) {
        if clearError {
            errorMessage = nil
        }
        do {
            _ = try YouTubeOAuthClientConfig.load()
            hasClientConfig = true
            AppLogger.auth.debug("OAuth client config detected")
        } catch {
            hasClientConfig = false
            isConnected = false
            hasWriteAccess = false
            statusTitle = "OAuth client config missing"
            statusDetail = "Import a Google OAuth desktop client JSON file from Settings before connecting."
            buttonTitle = "Connect YouTube"
            buttonSubtitle = "Import the downloaded OAuth client file, then authorize browser access"
            AppLogger.auth.error("OAuth client config missing")
            return
        }

        if let tokens = tokenStore.load() {
            isConnected = true
            hasWriteAccess = tokens.includesScope(YouTubeOAuthService.writeScope)
            let expiryText = tokens.expiresAt.map { Self.statusDateFormatter.string(from: $0) } ?? "unknown expiry"
            if hasWriteAccess {
                statusTitle = "YouTube API ready"
                statusDetail = "Stored OAuth token can read private playlists and save videos. Current access token expires \(expiryText)."
            } else {
                statusTitle = "Read-only YouTube access"
                statusDetail = "Private playlist reads work, but playlist saves and Watch Later need upgraded access. Reconnect YouTube to enable write actions."
            }
            buttonTitle = hasWriteAccess ? "Reconnect YouTube" : "Upgrade Access"
            buttonSubtitle = hasWriteAccess
                ? "Refresh browser authorization or switch to a different Google account"
                : "Approve expanded YouTube access for playlist saves and Watch Later"
            AppLogger.auth.info("OAuth tokens loaded. Expired: \(tokens.isExpired, privacy: .public)")
        } else {
            isConnected = false
            hasWriteAccess = false
            statusTitle = "YouTube not connected"
            statusDetail = "Authorize YouTube access so the app can verify private playlists and save videos to your playlists."
            buttonTitle = "Connect YouTube"
            buttonSubtitle = "Open the browser and approve access for private playlist sync and saves"
            AppLogger.auth.info("OAuth client config present but no stored tokens")
        }
    }

    func connect() {
        Task {
            await runConnectFlow()
        }
    }

    func disconnect() {
        AppLogger.auth.info("Clearing stored OAuth tokens")
        tokenStore.clear()
        refreshStatus(clearError: true)
    }

    private func runConnectFlow() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil

        defer {
            isBusy = false
        }

        do {
            let config = try YouTubeOAuthClientConfig.load()
            let service = YouTubeOAuthService(config: config)
            let redirect = OAuthLoopbackReceiver()
            let state = UUID().uuidString
            let redirectURI = try await redirect.start(expectedState: state)
            let request = service.authorizationRequest(redirectURI: redirectURI, state: state)
            AppLogger.auth.info("Starting OAuth browser flow on \(redirectURI, privacy: .public)")

            guard NSWorkspace.shared.open(request.url) else {
                AppLogger.auth.error("Failed to open OAuth authorization URL")
                throw NSError(domain: "YouTubeAuthController", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Could not open the OAuth authorization URL."
                ])
            }

            let code = try await redirect.waitForAuthorizationCode()
            AppLogger.auth.info("Received OAuth callback authorization code")
            _ = try await service.exchangeCode(code: code, redirectURI: redirectURI, codeVerifier: request.codeVerifier)
            AppLogger.auth.info("Stored OAuth tokens after successful exchange")
            refreshStatus(clearError: true)
        } catch {
            AppLogger.auth.error("OAuth flow failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            refreshStatus()
        }
    }

    private static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private actor OAuthLoopbackReceiverState {
    private var result: Result<String, Error>?

    func set(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
    }

    func get() -> Result<String, Error>? {
        result
    }
}

/// Loopback HTTP server that receives the OAuth redirect.
///
/// Marked `@unchecked Sendable` because `NWListener` and `DispatchQueue` are not Sendable.
/// Safety: `listener` is only created and torn down inside `start()`/`stop()` which run
/// sequentially on the same call site. Shared state is funnelled through the
/// actor-isolated `OAuthLoopbackReceiverState`, so no concurrent mutation occurs.
private final class OAuthLoopbackReceiver: @unchecked Sendable {
    private let port: UInt16
    private let path = "/oauth/callback"
    private let state = OAuthLoopbackReceiverState()
    private let queue = DispatchQueue(label: "YouTubeOAuthLoopback")
    private var listener: NWListener?
    private var expectedState: String?

    init(port: UInt16 = 8765) {
        self.port = port
    }

    func start(expectedState: String) async throws -> String {
        self.expectedState = expectedState
        let port = NWEndpoint.Port(rawValue: self.port)!
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener
        AppLogger.auth.debug("Starting OAuth loopback listener on port \(self.port)")

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.stateUpdateHandler = { [weak self] newState in
            if case .failed(let error) = newState {
                AppLogger.auth.error("OAuth loopback listener failed: \(error.localizedDescription, privacy: .public)")
                Task { await self?.state.set(.failure(error)) }
            }
        }

        listener.start(queue: queue)
        return "http://127.0.0.1:\(self.port)\(path)"
    }

    func waitForAuthorizationCode(timeoutSeconds: UInt64 = 180) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let result = await state.get() {
                listener?.cancel()
                return try result.get()
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        listener?.cancel()
        AppLogger.auth.error("Timed out waiting for OAuth authorization callback")
        throw NSError(domain: "YouTubeOAuthController", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for the browser authorization callback."
        ])
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                AppLogger.auth.error("OAuth loopback receive failed: \(error.localizedDescription, privacy: .public)")
                Task { await self.state.set(.failure(error)) }
                connection.cancel()
                return
            }

            let payload = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let parsed = self.parseRequest(payload)
            let response = self.makeHTTPResponse(for: parsed)

            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            Task {
                switch parsed {
                case .success(let code):
                    AppLogger.auth.debug("OAuth callback parsed successfully")
                    await self.state.set(.success(code))
                case .failure(let error):
                    AppLogger.auth.error("OAuth callback parse failed: \(error.localizedDescription, privacy: .public)")
                    await self.state.set(.failure(error))
                }
            }
        }
    }

    private func parseRequest(_ request: String) -> Result<String, Error> {
        guard let requestLine = request.split(separator: "\r\n", maxSplits: 1).first else {
            return .failure(NSError(domain: "YouTubeOAuthController", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Received an invalid OAuth callback request."
            ]))
        }

        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else {
            return .failure(NSError(domain: "YouTubeOAuthController", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Received a malformed OAuth callback request."
            ]))
        }

        let target = String(components[1])
        guard let url = URL(string: "http://127.0.0.1:\(port)\(target)"),
              url.path == path,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return .failure(NSError(domain: "YouTubeOAuthController", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Received an unexpected OAuth callback path."
            ]))
        }

        let code = items.first(where: { $0.name == "code" })?.value
        let returnedState = items.first(where: { $0.name == "state" })?.value
        let error = items.first(where: { $0.name == "error" })?.value

        if let error {
            return .failure(NSError(domain: "YouTubeOAuthController", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "OAuth authorization failed: \(error)"
            ]))
        }

        guard let code, !code.isEmpty else {
            return .failure(NSError(domain: "YouTubeOAuthController", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "OAuth callback did not include an authorization code."
            ]))
        }

        guard let returnedState, !returnedState.isEmpty else {
            return .failure(NSError(domain: "YouTubeOAuthController", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "OAuth callback did not include a state parameter."
            ]))
        }

        if let expectedState, returnedState != expectedState {
            return .failure(NSError(domain: "YouTubeOAuthController", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "OAuth callback state did not match the original request."
            ]))
        }

        return .success(code)
    }

    private func makeHTTPResponse(for result: Result<String, Error>) -> String {
        let body: String
        switch result {
        case .success:
            body = """
            <html><body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 24px;">
            <h2>YouTube connected</h2>
            <p>You can close this tab and return to Be Kind, Rewind.</p>
            </body></html>
            """
        case .failure(let error):
            body = """
            <html><body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 24px;">
            <h2>Authorization failed</h2>
            <p>\(error.localizedDescription)</p>
            </body></html>
            """
        }

        return """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
    }
}
