import Foundation

/// Matches the macOS Codex transport without pretending to be an OpenAI client.
/// This subscription-backed endpoint is compatibility-sensitive, not the public API.
enum ChatGPTResponsesTransport {
    static func sessionConfiguration(streaming: Bool = true) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // Non-streaming generation can remain silent until the full summary is ready.
        configuration.timeoutIntervalForRequest = streaming ? 120 : 300
        configuration.timeoutIntervalForResource = streaming ? 180 : 600
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func makeRequest(body: [String: Any], token: String, accountID: String,
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URLRequest {
        let legacy = environment["MUESLI_CHATGPT_TRANSPORT"]?.lowercased() == "wham"
        let lane = legacy ? "wham" : "codex"
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/\(lane)/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountID.isEmpty { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        if !legacy {
            request.setValue("muesli", forHTTPHeaderField: "originator")
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "iOS"
            request.setValue("Muesli/\(version)", forHTTPHeaderField: "User-Agent")
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "session_id")
        }
        var supported = body
        if !legacy { supported.removeValue(forKey: "max_output_tokens") }
        request.httpBody = try JSONSerialization.data(withJSONObject: supported)
        return request
    }
}

/// A partial stream is not a successful summary. Never save commentary/reasoning
/// or partial text when the provider fails or the connection ends prematurely.
struct SummaryResponseStream {
    private var delta = ""
    private(set) var completedText: String?
    private var receivedBytes = 0

    mutating func consume(line: String) throws {
        receivedBytes += line.utf8.count
        guard receivedBytes <= 2_000_000 else { throw failure("The response exceeded the supported size.") }
        guard line.hasPrefix("data:") else { return }
        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if ["", "[DONE]", "ping", "heartbeat", "keep-alive"].contains(raw) { return }
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("The response was malformed.")
        }
        let type = payload["type"] as? String ?? ""
        if ["error", "response.failed", "response.incomplete"].contains(type) || payload["error"] is [String: Any] {
            throw failure("The summary could not be completed. Please retry.")
        }
        if type == "response.output_text.delta", let text = payload["delta"] as? String { delta += text }
        if type == "response.completed" {
            guard let response = payload["response"] as? [String: Any],
                  response["status"] as? String == "completed" else { throw failure("The summary was interrupted.") }
            completedText = Self.outputText(response)
        }
        guard delta.utf8.count <= 256_000, (completedText?.utf8.count ?? 0) <= 256_000 else {
            throw failure("The response exceeded the supported size.")
        }
    }

    func result() throws -> String {
        guard let text = completedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw failure("The summary was interrupted. Please retry.")
        }
        return text
    }

    static func outputText(_ response: [String: Any]) -> String? {
        let items = (response["output"] as? [[String: Any]] ?? []).filter {
            $0["type"] as? String == "message" && $0["role"] as? String == "assistant"
        }
        let final = items.filter { $0["phase"] as? String == "final_answer" }
        let selected = final.isEmpty ? items.filter { $0["phase"] as? String != "commentary" } : final
        let text = selected.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        if !text.isEmpty { return text }
        return response["output_text"] as? String
    }

    private func failure(_ message: String) -> MeetingSummaryError {
        .backendFailed(backend: "ChatGPT", statusCode: nil, message: message)
    }
}
