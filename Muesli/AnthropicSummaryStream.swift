import Foundation

/// Mirrors macOS MeetingSummaryOutputPolicy: Anthropic requires a maximum,
/// while large budgets must use streaming to avoid long-request HTTP rejection.
enum AnthropicSummaryPolicy {
    static func modelMaximum(_ model: String) -> Int? {
        switch model {
        case "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1", "claude-haiku-5-5": 128_000
        case "claude-haiku-4-5", "claude-haiku-4-5-20251001": 64_000
        default: nil
        }
    }

    static func maximum(model: String, apiKey: String, session: URLSession) async throws -> Int {
        if let maximum = modelMaximum(model) { return maximum }
        var url = URLComponents(string: "https://api.anthropic.com/v1/models")!
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        url.percentEncodedPath += "/" + (model.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let maximum = json["max_tokens"] as? Int, maximum > 0 else {
            throw MeetingSummaryError.backendFailed(backend: "Anthropic", statusCode: (response as? HTTPURLResponse)?.statusCode,
                message: "The model's output limit could not be determined. Choose a listed model and try again.")
        }
        return maximum
    }
}

struct AnthropicSummaryStream {
    private var blocks: [Int: String] = [:]
    private var sawStopReason = false
    private var bytes = 0
    private(set) var finished = false

    mutating func consume(line: String) throws {
        bytes += line.utf8.count
        guard bytes <= 2_000_000 else { throw failure() }
        guard line.hasPrefix("data:") else { return }
        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        guard let event = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw failure() }
        switch event["type"] as? String {
        case "content_block_start":
            if let index = event["index"] as? Int, index >= 0, index < 256,
               let block = event["content_block"] as? [String: Any], block["type"] as? String == "text" {
                blocks[index] = block["text"] as? String ?? ""
            }
        case "content_block_delta":
            if let index = event["index"] as? Int,
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, blocks[index] != nil { blocks[index, default: ""] += text }
        case "message_delta":
            guard let delta = event["delta"] as? [String: Any],
                  let reason = delta["stop_reason"] as? String,
                  ["end_turn", "stop_sequence"].contains(reason) else { throw failure() }
            sawStopReason = true
        case "message_stop":
            guard sawStopReason else { throw failure() }
            finished = true
        case "error": throw failure()
        default: break
        }
    }

    func result() throws -> String {
        let text = blocks.keys.sorted().compactMap { blocks[$0] }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard finished, !text.isEmpty else { throw failure() }
        return text
    }

    private func failure() -> MeetingSummaryError {
        .backendFailed(backend: "Anthropic", statusCode: nil, message: "The summary was interrupted or reached the model's limit. Please retry.")
    }
}
