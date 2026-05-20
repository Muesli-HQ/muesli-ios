import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security
import UIKit

enum ChatGPTAuthError: Error, LocalizedError {
    case notAuthenticated
    case authorizationURLFailed
    case callbackTimeout
    case callbackMissingCode
    case callbackStateMismatch
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case portInUse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Not signed in to ChatGPT."
        case .authorizationURLFailed:
            "Could not create the ChatGPT sign-in URL."
        case .callbackTimeout:
            "ChatGPT sign-in timed out."
        case .callbackMissingCode:
            "ChatGPT sign-in did not return an authorization code."
        case .callbackStateMismatch:
            "ChatGPT sign-in failed security validation."
        case .tokenExchangeFailed(let message):
            "ChatGPT token exchange failed: \(message)"
        case .refreshFailed(let message):
            "ChatGPT token refresh failed: \(message)"
        case .portInUse:
            "ChatGPT sign-in callback port is already in use."
        }
    }
}

@MainActor
final class ChatGPTAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = ChatGPTAuthManager()

    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let callbackPort: UInt16 = 1455
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scopes = "openid profile email offline_access"
    private static let callbackTimeoutSeconds: TimeInterval = 300
    private static let keychainService = "com.phequals7.muesli.ios.chatgpt-auth"

    private let keychain = KeychainStore(service: keychainService)
    private var activeSession: ASWebAuthenticationSession?

    var isAuthenticated: Bool {
        (try? keychain.string(for: "access_token")) != nil
    }

    func signIn() async throws {
        let (verifier, challenge) = generatePKCE()
        let code = try await startCallbackServerAndAuthenticate(codeChallenge: challenge)
        let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: verifier)
        try saveTokens(tokens)
    }

    func signOut() {
        ["access_token", "refresh_token", "expires_at", "account_id"].forEach {
            keychain.delete(account: $0)
        }
    }

    func validAccessToken() async throws -> (token: String, accountId: String) {
        guard let accessToken = try keychain.string(for: "access_token") else {
            throw ChatGPTAuthError.notAuthenticated
        }
        let accountId = try keychain.string(for: "account_id") ?? ""
        let expiryText = try keychain.string(for: "expires_at") ?? ""
        if let expiryMs = Double(expiryText) {
            let expiresAt = Date(timeIntervalSince1970: expiryMs / 1000.0)
            if expiresAt > Date().addingTimeInterval(30) {
                return (accessToken, accountId)
            }
        }

        guard let refreshToken = try keychain.string(for: "refresh_token"), !refreshToken.isEmpty else {
            throw ChatGPTAuthError.notAuthenticated
        }
        let tokens = try await refreshAccessToken(refreshToken: refreshToken)
        try saveTokens(tokens)
        return (tokens.accessToken, tokens.accountId)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: MuesliAppConstants.urlScheme
            ) { callbackURL, error in
                self.activeSession = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? ChatGPTAuthError.callbackMissingCode)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            session.start()
        }
    }

    private func startCallbackServerAndAuthenticate(codeChallenge: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let port = NWEndpoint.Port(rawValue: Self.callbackPort)!
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

            guard let listener = try? NWListener(using: params) else {
                continuation.resume(throwing: ChatGPTAuthError.portInUse)
                return
            }

            let expectedState = generateState()
            let callbackState = OAuthCallbackState()

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.callbackTimeoutSeconds))
                guard callbackState.markResumed() else { return }
                listener.cancel()
                await MainActor.run {
                    self?.activeSession?.cancel()
                    self?.activeSession = nil
                }
                continuation.resume(throwing: ChatGPTAuthError.callbackTimeout)
            }

            listener.stateUpdateHandler = { state in
                if case .failed = state {
                    guard callbackState.markResumed() else { return }
                    continuation.resume(throwing: ChatGPTAuthError.portInUse)
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    defer { listener.cancel() }
                    guard callbackState.markResumed() else { return }

                    guard let data,
                          let request = String(data: data, encoding: .utf8) else {
                        Self.sendCallbackPage(
                            connection: connection,
                            status: "400 Bad Request",
                            title: "Sign-in failed",
                            detail: "Muesli could not read the ChatGPT callback."
                        )
                        continuation.resume(throwing: ChatGPTAuthError.callbackMissingCode)
                        return
                    }

                    let returnedState = Self.extractParam(named: "state", from: request)
                    guard returnedState == expectedState else {
                        Self.sendCallbackPage(
                            connection: connection,
                            status: "400 Bad Request",
                            title: "Sign-in failed",
                            detail: "Security validation failed. Please try again."
                        )
                        continuation.resume(throwing: ChatGPTAuthError.callbackStateMismatch)
                        return
                    }

                    guard let code = Self.extractParam(named: "code", from: request), !code.isEmpty else {
                        Self.sendCallbackPage(
                            connection: connection,
                            status: "400 Bad Request",
                            title: "Sign-in failed",
                            detail: "ChatGPT did not return an authorization code."
                        )
                        continuation.resume(throwing: ChatGPTAuthError.callbackMissingCode)
                        return
                    }

                    Self.sendCallbackPage(
                        connection: connection,
                        status: "200 OK",
                        title: "Signed in to Muesli",
                        detail: "You can close this window and return to Muesli."
                    )
                    Task { @MainActor [weak self] in
                        self?.activeSession?.cancel()
                        self?.activeSession = nil
                    }
                    continuation.resume(returning: code)
                }
            }

            listener.start(queue: .main)

            guard let url = authorizationURL(codeChallenge: codeChallenge, state: expectedState) else {
                listener.cancel()
                guard callbackState.markResumed() else { return }
                continuation.resume(throwing: ChatGPTAuthError.authorizationURLFailed)
                return
            }

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: nil
            ) { [weak listener, weak self] _, error in
                guard callbackState.markResumed() else { return }
                listener?.cancel()
                Task { @MainActor in
                    self?.activeSession = nil
                    continuation.resume(throwing: error ?? ChatGPTAuthError.callbackMissingCode)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            if !session.start() {
                guard callbackState.markResumed() else { return }
                listener.cancel()
                activeSession = nil
                continuation.resume(throwing: ChatGPTAuthError.authorizationURLFailed)
            }
        }
    }

    private func authorizationURL(codeChallenge: String, state: String) -> URL? {
        var components = URLComponents(url: Self.authURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "opencode"),
        ]
        return components?.url
    }

    nonisolated private static func extractParam(named name: String, from httpRequest: String) -> String? {
        guard let pathLine = httpRequest.split(separator: "\r\n").first ?? httpRequest.split(separator: "\n").first,
              let pathPart = pathLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(pathPart)) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    nonisolated private static func sendCallbackPage(connection: NWConnection, status: String, title: String, detail: String) {
        let escapedTitle = title.htmlEscaped()
        let escapedDetail = detail.htmlEscaped()
        let html = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Connection: close\r
        \r
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#111;color:#f5f5f7;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;padding:24px;text-align:center}p{color:#a1a1aa;line-height:1.45}</style></head><body><main><h1>\(escapedTitle)</h1><p>\(escapedDetail)</p></main></body></html>
        """
        connection.send(
            content: html.data(using: .utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        return (verifier, challengeData.base64URLEncoded())
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String
        let expiresAtMs: Double
        let accountId: String
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> TokenResponse {
        let body = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": codeVerifier,
        ]
        let (data, response) = try await tokenRequest(body: body)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ChatGPTAuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        return try parseTokenResponse(data, fallbackRefreshToken: "")
    }

    private func refreshAccessToken(refreshToken: String) async throws -> TokenResponse {
        let body = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ]
        let (data, response) = try await tokenRequest(body: body)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ChatGPTAuthError.refreshFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        return try parseTokenResponse(data, fallbackRefreshToken: refreshToken)
    }

    private func tokenRequest(body: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(body).data(using: .utf8)
        return try await URLSession.shared.data(for: request)
    }

    private func formEncoded(_ values: [String: String]) -> String {
        values.map { key, value in
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }
        .joined(separator: "&")
    }

    private func parseTokenResponse(_ data: Data, fallbackRefreshToken: String) throws -> TokenResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw ChatGPTAuthError.tokenExchangeFailed("missing access_token")
        }
        let refreshToken = json["refresh_token"] as? String ?? fallbackRefreshToken
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let expiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000.0
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMs: expiresAtMs,
            accountId: extractAccountId(from: accessToken)
        )
    }

    private func saveTokens(_ tokens: TokenResponse) throws {
        try keychain.set(tokens.accessToken, for: "access_token")
        try keychain.set(tokens.refreshToken, for: "refresh_token")
        try keychain.set(String(format: "%.0f", tokens.expiresAtMs), for: "expires_at")
        try keychain.set(tokens.accountId, for: "account_id")
    }

    private func extractAccountId(from jwt: String) -> String {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return "" }
        var payload = String(segments[1])
        while payload.count % 4 != 0 {
            payload += "="
        }
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        if let accountId = json["chatgpt_account_id"] as? String {
            return accountId
        }
        if let authClaims = json["https://api.openai.com/auth"] as? [String: Any],
           let accountId = authClaims["chatgpt_account_id"] as? String {
            return accountId
        }
        if let orgs = json["organizations"] as? [[String: Any]],
           let orgId = orgs.first?["id"] as? String {
            return orgId
        }
        return ""
    }
}

private final class OAuthCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    func htmlEscaped() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
