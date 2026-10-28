import XCTest
@testable import Muesli

@MainActor
private final class MemoryChatGPTStore: ChatGPTCredentialStore {
    var values: [String: String] = [:]
    var failWrites = false
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws {
        if failWrites { throw ChatGPTAuthError.invalidResponse }
        values[account] = value
    }
    func delete(account: String) { values.removeValue(forKey: account) }
}

private actor AuthNetwork {
    var requests: [URLRequest] = []
    var replies: [(Int, String)]
    var gate: CheckedContinuation<Void, Never>?
    var block = false
    init(_ replies: [(Int, String)]) { self.replies = replies }
    func setBlocked() { block = true }
    func release() { block = false; gate?.resume(); gate = nil }
    var count: Int { requests.count }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if block { await withCheckedContinuation { gate = $0 } }
        guard !replies.isEmpty else { throw ChatGPTAuthError.invalidResponse }
        let (status, json) = replies.removeFirst()
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class ChatGPTAuthTests: XCTestCase {
    private let tokens = #"{"access_token":"new-access","refresh_token":"rotated","expires_in":3600}"#
    private let code = #"{"device_auth_id":"device","user_code":"ABCD-1234","interval":"1"}"#

    @MainActor
    private func legacyStore() -> MemoryChatGPTStore {
        let store = MemoryChatGPTStore()
        store.values = ["access_token": "old", "refresh_token": "refresh", "expires_at": "0", "account_id": "account"]
        return store
    }

    func testDeviceCodeAliasesAndMinimumInterval() throws {
        let now = Date(timeIntervalSince1970: 100)
        let value = try ChatGPTDeviceCode.decode(Data(#"{"device_auth_id":"d","usercode":"code","interval":0}"#.utf8), now: now)
        XCTAssertEqual(value.userCode, "code")
        XCTAssertEqual(value.interval, 1)
        XCTAssertEqual(value.expiresAt, now.addingTimeInterval(900))
        XCTAssertThrowsError(try ChatGPTDeviceCode.decode(Data(#"{"device_auth_id":"","usercode":"c"}"#.utf8), now: now))
    }

    @MainActor
    func testDeviceCodeLoginPollsThenStoresAtomicSession() async throws {
        let store = legacyStore()
        let network = AuthNetwork([(200, code), (403, "{}"), (200, #"{"authorization_code":"auth","code_verifier":"verify"}"#), (200, tokens)])
        let auth = ChatGPTAuthManager(store: store, send: { try await network.send($0) }, sleep: { _ in })
        var displayedCode = ""
        try await auth.signIn { displayedCode = $0.userCode }
        XCTAssertEqual(displayedCode, "ABCD-1234")
        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertNotNil(store.values["session"])
        XCTAssertNil(store.values["access_token"])
        let requests = await network.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].url?.path, "/api/accounts/deviceauth/usercode")
        let exchange = String(decoding: try XCTUnwrap(requests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(exchange.contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"))
    }

    @MainActor
    func testSignOutDuringLoginCannotRestoreCredentials() async throws {
        let store = legacyStore()
        let network = AuthNetwork([(200, code)])
        let auth = ChatGPTAuthManager(store: store, send: { try await network.send($0) })
        do {
            try await auth.signIn { _ in auth.signOut() }
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertTrue(store.values.isEmpty)
    }

    @MainActor
    func testFailedReplacementPreservesLegacySession() async throws {
        let store = legacyStore()
        let network = AuthNetwork([(404, "{}")])
        let auth = ChatGPTAuthManager(store: store, send: { try await network.send($0) })
        do { try await auth.signIn { _ in }; XCTFail("Expected unavailable") }
        catch ChatGPTAuthError.deviceLoginUnavailable {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(store.values["access_token"], "old")
    }

    @MainActor
    func testConcurrentRefreshUsesOneRequestAndKeepsAccountID() async throws {
        let store = legacyStore()
        let network = AuthNetwork([(200, tokens)])
        await network.setBlocked()
        let auth = ChatGPTAuthManager(store: store, send: { try await network.send($0) })
        let first = Task { try await auth.validAccessToken() }
        let second = Task { try await auth.validAccessToken() }
        while await network.count == 0 { await Task.yield() }
        await Task.yield()
        await network.release()
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a.token, "new-access")
        XCTAssertEqual(b.accountId, "account")
        let count = await network.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testLogoutDuringRefreshRejectsLateResponse() async throws {
        let store = legacyStore()
        let network = AuthNetwork([(200, tokens)])
        await network.setBlocked()
        let auth = ChatGPTAuthManager(store: store, send: { try await network.send($0) })
        let task = Task { try await auth.validAccessToken() }
        while await network.count == 0 { await Task.yield() }
        auth.signOut()
        await network.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(store.values.isEmpty)
    }

    @MainActor
    func testFailedAtomicSavePreservesLegacyCredentials() async throws {
        let store = legacyStore()
        store.failWrites = true
        let network = AuthNetwork([(200, tokens)])
        let auth = ChatGPTAuthManager(store: store, send: { try await network.send($0) })
        do { _ = try await auth.validAccessToken(); XCTFail("Expected keychain failure") } catch {}
        XCTAssertEqual(store.values["refresh_token"], "refresh")
        XCTAssertNil(store.values["session"])
    }

    func testRefreshWithoutRotatedTokenKeepsExistingToken() throws {
        let prior = ChatGPTTokens(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast, accountID: "account")
        let result = try ChatGPTTokens.decode(Data(#"{"access_token":"new"}"#.utf8), now: Date(), previous: prior)
        XCTAssertEqual(result.refreshToken, "refresh")
        XCTAssertEqual(result.accountID, "account")
    }
}
