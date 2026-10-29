import XCTest
@testable import Muesli

final class SummaryBackendTests: XCTestCase {
    func testNonStreamingSummaryRequestsAllowLongGeneration() throws {
        let config = ChatGPTResponsesTransport.sessionConfiguration(streaming: false)
        XCTAssertEqual(config.timeoutIntervalForRequest, 300)
        XCTAssertEqual(config.timeoutIntervalForResource, 600)
        for backend: MeetingSummaryBackend in [.openAI, .anthropic] {
            let request = try MeetingSummaryClient.publicAPIRequest(backend: backend, model: "test", apiKey: "test", systemPrompt: "", userPrompt: "", maxTokens: 2500)
            XCTAssertEqual(request.timeoutInterval, config.timeoutIntervalForRequest)
        }
    }

    func testStreamingTimeoutsRemainBounded() throws {
        let config = ChatGPTResponsesTransport.sessionConfiguration()
        XCTAssertEqual(config.timeoutIntervalForRequest, 120)
        XCTAssertEqual(config.timeoutIntervalForResource, 180)
        let request = try MeetingSummaryClient.publicAPIRequest(backend: .anthropic, model: "test", apiKey: "test", systemPrompt: "", userPrompt: "", maxTokens: 128_000)
        XCTAssertEqual(request.timeoutInterval, config.timeoutIntervalForRequest)
    }

    func testCodexTransportHeadersAndUnsupportedTokenCap() throws {
        let request = try ChatGPTResponsesTransport.makeRequest(body: ["model": "test", "max_output_tokens": 3, "store": false], token: "test-token", accountID: "account", environment: [:])
        XCTAssertEqual(request.url?.path, "/backend-api/codex/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "muesli")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(request.value(forHTTPHeaderField: "session_id"))))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["max_output_tokens"])
    }

    func testLegacyTransportRequiresExplicitOverride() throws {
        let request = try ChatGPTResponsesTransport.makeRequest(body: [:], token: "t", accountID: "", environment: ["MUESLI_CHATGPT_TRANSPORT": "wham"])
        XCTAssertEqual(request.url?.path, "/backend-api/wham/responses")
        XCTAssertNil(request.value(forHTTPHeaderField: "originator"))
    }

    func testPartialOrFailedStreamNeverSucceeds() throws {
        var stream = SummaryResponseStream()
        try stream.consume(line: #"data: {"type":"response.output_text.delta","delta":"partial"}"#)
        XCTAssertThrowsError(try stream.result())
        XCTAssertThrowsError(try stream.consume(line: #"data: {"type":"response.failed","response":{"error":{"message":"failed"}}}"#))
    }

    func testCompletedFinalAnswerExcludesCommentaryAndReasoning() throws {
        var stream = SummaryResponseStream()
        try stream.consume(line: #"data: {"type":"response.output_text.delta","delta":"commentary"}"#)
        try stream.consume(line: #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","text":"private"},{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"commentary"}]},{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Final notes"}]}]}}"#)
        XCTAssertEqual(try stream.result(), "Final notes")
    }

    func testMalformedAndIncompleteStreamsFail() throws {
        var stream = SummaryResponseStream()
        XCTAssertThrowsError(try stream.consume(line: "data: broken"))
        XCTAssertThrowsError(try stream.consume(line: #"data: {"type":"response.incomplete"}"#))
    }

    func testOpenAIUsesResponsesWithoutArbitraryReasoningCap() throws {
        let request = try MeetingSummaryClient.publicAPIRequest(backend: .openAI, model: "model", apiKey: "test", systemPrompt: "system", userPrompt: "transcript", maxTokens: 80)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["max_output_tokens"])
    }

    func testAnthropicUsesMessagesAndRequiredHeaders() throws {
        let request = try MeetingSummaryClient.publicAPIRequest(backend: .anthropic, model: "model", apiKey: "test", systemPrompt: "system", userPrompt: "transcript", maxTokens: 2500)
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testProviderTruncationIsFailure() throws {
        XCTAssertThrowsError(try MeetingSummaryClient.publicAPIText(Data(#"{"status":"incomplete","output_text":"partial"}"#.utf8), backend: .openAI))
        XCTAssertThrowsError(try MeetingSummaryClient.publicAPIText(Data(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#.utf8), backend: .anthropic))
        XCTAssertEqual(try MeetingSummaryClient.publicAPIText(Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"notes"}]}"#.utf8), backend: .anthropic), "notes")
    }

    func testCompletedCommentaryOnlyCannotFallBackToDelta() throws {
        var stream = SummaryResponseStream()
        try stream.consume(line: #"data: {"type":"response.output_text.delta","delta":"Working on this"}"#)
        try stream.consume(line: #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Working on this"}]}]}}"#)
        XCTAssertThrowsError(try stream.result())
    }

    func testOpenRouterRequiresSuccessfulFinishReason() {
        let message: [String: Any] = ["content": "partial"]
        XCTAssertNil(MeetingSummaryClient.extractChatCompletionsText(from: ["choices": [["finish_reason": "length", "message": message]]]))
        XCTAssertNil(MeetingSummaryClient.extractChatCompletionsText(from: ["choices": [["finish_reason": "error", "message": message]]]))
        XCTAssertEqual(MeetingSummaryClient.extractChatCompletionsText(from: ["choices": [["finish_reason": "stop", "message": message]]]), "partial")
    }

    func testAnthropicMaximumAndStreamingCompletion() throws {
        XCTAssertEqual(AnthropicSummaryPolicy.modelMaximum("claude-sonnet-5-5"), 128_000)
        XCTAssertEqual(AnthropicSummaryPolicy.modelMaximum("claude-haiku-4-5-20251001"), 64_000)
        XCTAssertNil(AnthropicSummaryPolicy.modelMaximum("custom"))
        let request = try MeetingSummaryClient.publicAPIRequest(backend: .anthropic, model: "claude-sonnet-5-5", apiKey: "test", systemPrompt: "system", userPrompt: "notes", maxTokens: 128_000)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        var stream = AnthropicSummaryStream()
        try stream.consume(line: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        try stream.consume(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"notes"}}"#)
        XCTAssertThrowsError(try stream.result())
        try stream.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)
        try stream.consume(line: #"data: {"type":"message_stop"}"#)
        XCTAssertEqual(try stream.result(), "notes")
    }

    func testAnthropicTokenLimitAndMissingTerminalFail() throws {
        var stream = AnthropicSummaryStream()
        XCTAssertThrowsError(try stream.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#))
        XCTAssertThrowsError(try stream.consume(line: #"data: {"type":"message_stop"}"#))
    }

    func testSavedChatGPTModelIsNotSilentlyReplaced() {
        let key = MuesliPreferences.chatGPTModelKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set("gpt-5.5", forKey: key)
        XCTAssertEqual(MuesliPreferences.chatGPTModel, "gpt-5.5")
        UserDefaults.standard.set("my-model", forKey: key)
        XCTAssertEqual(MuesliPreferences.chatGPTModel, "my-model")
        UserDefaults.standard.set("  ", forKey: key)
        XCTAssertEqual(MuesliPreferences.chatGPTModel, MeetingSummaryBackend.defaultChatGPTModel)
    }

    func testCatalogKeepsSubscriptionAndAPIModelsSeparate() {
        XCTAssertEqual(MeetingSummaryBackend.defaultChatGPTModel, "gpt-6.1-sol")
        XCTAssertEqual(MeetingSummaryBackend.defaultOpenRouterModel, "openrouter/free")
        XCTAssertFalse(SummaryModelPreset.chatGPTModels.contains { $0.id == "chat-latest" })
        XCTAssertTrue(SummaryModelPreset.openAIModels.contains { $0.id == "chat-latest" })
        XCTAssertEqual(Set(MeetingSummaryBackend.allCases.map(\.modelPreferenceKey)).count, 4)
    }
}
