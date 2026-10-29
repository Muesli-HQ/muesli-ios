import Foundation

// Keep the existing Keychain service/accounts readable so upgrading never requires
// signing in again. New sessions use one atomic Keychain record.
@MainActor
protocol ChatGPTCredentialStore {
    func string(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func delete(account: String)
}
extension KeychainStore: ChatGPTCredentialStore {}

enum ChatGPTAuthError: Error, LocalizedError {
    case notAuthenticated, signInInProgress, expiredCode, invalidResponse
    case requestFailed(Int)
    case deviceLoginUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to ChatGPT to continue."
        case .signInInProgress: "A ChatGPT sign-in is already in progress."
        case .expiredCode: "This sign-in code expired. Please try again."
        case .invalidResponse: "ChatGPT returned an unexpected sign-in response."
        case .requestFailed(let status): "ChatGPT sign-in failed (HTTP \(status)). Please try again."
        case .deviceLoginUnavailable: "Device code sign-in is unavailable. Enable device code login in your ChatGPT security settings, or ask your workspace administrator."
        }
    }
}

struct ChatGPTDeviceCode: Sendable {
    let userCode: String
    let deviceAuthID: String
    let interval: TimeInterval
    let expiresAt: Date
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!

    static func decode(_ data: Data, now: Date) throws -> Self {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["device_auth_id"] as? String, !id.isEmpty,
              let code = (json["user_code"] ?? json["usercode"]) as? String, !code.isEmpty else {
            throw ChatGPTAuthError.invalidResponse
        }
        let rawInterval = (json["interval"] as? Double) ?? Double(json["interval"] as? String ?? "") ?? 5
        return Self(userCode: code, deviceAuthID: id, interval: min(max(rawInterval, 1), 60),
                    expiresAt: now.addingTimeInterval(900))
    }
}

struct ChatGPTTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let accountID: String

    static func decode(_ data: Data, now: Date, previous: Self? = nil) throws -> Self {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw ChatGPTAuthError.invalidResponse
        }
        let refresh = json["refresh_token"] as? String ?? previous?.refreshToken ?? ""
        guard !refresh.isEmpty else { throw ChatGPTAuthError.invalidResponse }
        let account = accountID(from: access)
        return Self(accessToken: access, refreshToken: refresh,
                    expiresAt: now.addingTimeInterval((json["expires_in"] as? Double) ?? 3600),
                    accountID: account.isEmpty ? (previous?.accountID ?? "") : account)
    }

    static func accountID(from jwt: String) -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return "" }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let claims = json["https://api.openai.com/auth"] as? [String: Any]
        return (claims?["chatgpt_account_id"] as? String) ?? (json["chatgpt_account_id"] as? String) ?? ""
    }
}

@MainActor
final class ChatGPTAuthManager {
    static let shared = ChatGPTAuthManager()
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let legacyAccounts = ["access_token", "refresh_token", "expires_at", "account_id"]
    private let store: any ChatGPTCredentialStore
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var generation = UUID()
    private var signInID: UUID?
    private var refreshID: UUID?
    private var refreshTask: Task<ChatGPTTokens, Error>?

    init(store: (any ChatGPTCredentialStore)? = nil,
         send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.store = store ?? KeychainStore(service: "\(MuesliAppConstants.bundleIdentifier).chatgpt-auth")
        self.send = send
        self.now = now
        self.sleep = sleep
    }

    var isAuthenticated: Bool { (try? loadTokens()) != nil }

    // Uses the Codex device-code protocol, avoiding a localhost listener on iOS.
    // https://github.com/openai/codex/blob/main/codex-rs/login/src/device_code_auth.rs
    func signIn(onCode: @MainActor (ChatGPTDeviceCode) -> Void) async throws {
        guard signInID == nil else { throw ChatGPTAuthError.signInInProgress }
        let id = UUID()
        signInID = id
        let epoch = generation
        defer { if signInID == id { signInID = nil } }
        func checkActive() throws {
            try Task.checkCancellation()
            guard generation == epoch, signInID == id else { throw CancellationError() }
        }
        let data = try await request(path: "/api/accounts/deviceauth/usercode", body: ["client_id": Self.clientID])
        try checkActive()
        let code = try ChatGPTDeviceCode.decode(data, now: now())
        onCode(code)
        while now() < code.expiresAt {
            try checkActive()
            let request = try Self.jsonRequest(path: "/api/accounts/deviceauth/token", body: ["device_auth_id": code.deviceAuthID, "user_code": code.userCode])
            let (responseData, response) = try await send(request)
            try checkActive()
            guard now() < code.expiresAt else { throw ChatGPTAuthError.expiredCode }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403 || status == 404 {
                try await sleep(min(code.interval, code.expiresAt.timeIntervalSince(now())))
                continue
            }
            guard (200..<300).contains(status) else { throw ChatGPTAuthError.requestFailed(status) }
            guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let authorizationCode = json["authorization_code"] as? String, !authorizationCode.isEmpty,
                  let verifier = json["code_verifier"] as? String, !verifier.isEmpty else { throw ChatGPTAuthError.invalidResponse }
            let tokenData = try await tokenRequest(body: ["grant_type": "authorization_code", "client_id": Self.clientID,
                "code": authorizationCode, "code_verifier": verifier, "redirect_uri": "https://auth.openai.com/deviceauth/callback"])
            try checkActive()
            let tokens = try ChatGPTTokens.decode(tokenData, now: now())
            // Invalidate an older refresh before installing this new account.
            refreshTask?.cancel()
            refreshTask = nil
            refreshID = nil
            generation = UUID()
            try saveTokens(tokens)
            return
        }
        throw ChatGPTAuthError.expiredCode
    }

    func signOut() {
        generation = UUID()
        signInID = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        store.delete(account: "session")
        Self.legacyAccounts.forEach { store.delete(account: $0) }
    }

    func validAccessToken() async throws -> (token: String, accountId: String) {
        try Task.checkCancellation()
        guard let stored = try loadTokens() else { throw ChatGPTAuthError.notAuthenticated }
        if stored.expiresAt > now().addingTimeInterval(30) { return (stored.accessToken, stored.accountID) }
        guard !stored.refreshToken.isEmpty else { throw ChatGPTAuthError.notAuthenticated }
        let epoch = generation
        if refreshTask == nil {
            refreshID = UUID()
            refreshTask = Task {
                let data = try await self.tokenRequest(body: ["grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": stored.refreshToken])
                try Task.checkCancellation()
                guard self.generation == epoch else { throw ChatGPTAuthError.notAuthenticated }
                let tokens = try ChatGPTTokens.decode(data, now: self.now(), previous: stored)
                try self.saveTokens(tokens)
                return tokens
            }
        }
        guard let task = refreshTask, let flight = refreshID else { throw ChatGPTAuthError.notAuthenticated }
        defer {
            if refreshID == flight { refreshTask = nil; refreshID = nil }
        }
        let tokens: ChatGPTTokens
        do {
            tokens = try await task.value
        } catch {
            // Cancelling a shared refresh on logout is not cancellation of the
            // caller's meeting. Let it save the transcript with a failed summary.
            try Task.checkCancellation()
            guard generation == epoch else { throw ChatGPTAuthError.notAuthenticated }
            throw error
        }
        try Task.checkCancellation()
        guard generation == epoch else { throw ChatGPTAuthError.notAuthenticated }
        return (tokens.accessToken, tokens.accountID)
    }

    private func loadTokens() throws -> ChatGPTTokens? {
        if let record = try store.string(for: "session") {
            return try JSONDecoder().decode(ChatGPTTokens.self, from: Data(record.utf8))
        }
        guard let access = try store.string(for: "access_token"), !access.isEmpty else { return nil }
        let milliseconds = Double(try store.string(for: "expires_at") ?? "") ?? 0
        return ChatGPTTokens(accessToken: access, refreshToken: try store.string(for: "refresh_token") ?? "",
                             expiresAt: Date(timeIntervalSince1970: milliseconds / 1000), accountID: try store.string(for: "account_id") ?? "")
    }

    private func saveTokens(_ tokens: ChatGPTTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        try store.set(String(decoding: data, as: UTF8.self), for: "session")
        Self.legacyAccounts.forEach { store.delete(account: $0) }
    }

    private func request(path: String, body: [String: String]) async throws -> Data {
        let (data, response) = try await send(Self.jsonRequest(path: path, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 403 || status == 404 { throw ChatGPTAuthError.deviceLoginUnavailable }
            throw ChatGPTAuthError.requestFailed(status)
        }
        return data
    }

    static func jsonRequest(path: String, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://auth.openai.com" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func tokenRequest(body: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = body.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ChatGPTAuthError.requestFailed(status) }
        return data
    }
}
