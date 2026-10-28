import Foundation

enum MeetingSummaryError: Error, LocalizedError {
    case missingCredentials(MeetingSummaryBackend)
    case backendFailed(backend: String, statusCode: Int?, message: String)
    case emptyResponse(String)
    case requestFailed(backend: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let backend):
            "\(backend.label) is not configured."
        case let .backendFailed(backend, statusCode, message):
            "\(backend) could not generate meeting notes\(statusCode.map { " (HTTP \($0))" } ?? ""). \(message)"
        case .emptyResponse(let backend):
            "\(backend) returned an empty meeting summary."
        case let .requestFailed(backend, underlying):
            "\(backend) could not be reached. \(underlying.localizedDescription)"
        }
    }
}

enum MeetingSummaryClient {
    static let openRouterAPIKeyAccount = "openrouter_api_key"

    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let maxOutputTokens = 16_384
    private static let keychain = KeychainStore(service: "\(MuesliAppConstants.bundleIdentifier).summary")

    private static let baseSummaryInstructions = """
    You are a meeting notes assistant. Given a raw meeting transcript, produce concise, professional markdown notes.
    Do not invent facts. Prefer concrete takeaways over filler. Capture owners only when they are actually mentioned.
    If a requested section has no content, write "None noted."
    """

    private static let titleInstructions = """
    Generate a short, descriptive meeting title (3-7 words) from this transcript.
    Return only the title text, with no quotes, prefix, or explanation.
    """

    static func storedAPIKey(for backend: MeetingSummaryBackend) -> String {
        (try? keychain.string(for: "\(backend.rawValue)_api_key")) ?? ""
    }

    static func saveAPIKey(_ apiKey: String, for backend: MeetingSummaryBackend) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = "\(backend.rawValue)_api_key"
        if trimmed.isEmpty { keychain.delete(account: account) }
        else { try keychain.set(trimmed, for: account) }
    }

    static func storedOpenRouterAPIKey() -> String { storedAPIKey(for: .openRouter) }
    static func saveOpenRouterAPIKey(_ key: String) throws { try saveAPIKey(key, for: .openRouter) }

    static func summarize(
        transcript: String,
        meetingTitle: String,
        manualNotesToRetain: String? = nil,
        configuration: MeetingSummaryConfiguration = .current()
    ) async throws -> MeetingSummaryResult {
        // Snapshot the user's choices before the first suspension point. A settings
        // change during generation must not send the title to a different provider.
        let backend = configuration.backend
        let model = configuration.model
        let template = configuration.template
        let apiKey = configuration.apiKey
        try Task.checkCancellation()
        let notes = try await generate(backend: backend, model: model, apiKey: apiKey,
            systemPrompt: baseSummaryInstructions,
            userPrompt: summaryPrompt(transcript: transcript, meetingTitle: meetingTitle,
                                      manualNotesToRetain: manualNotesToRetain, template: template), maxTokens: maxOutputTokens)
        try Task.checkCancellation()
        let title: String
        do {
            title = try await generate(backend: backend, model: model, apiKey: apiKey,
                systemPrompt: titleInstructions, userPrompt: String(transcript.prefix(6000)) + optionalNotesSection(header: "Written notes:", notes: manualNotesToRetain), maxTokens: 1024)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            title = meetingTitle
        }
        try Task.checkCancellation()
        return MeetingSummaryResult(notes: notes, title: title.isEmpty ? meetingTitle : title, backend: backend, model: model)
    }

    static func failureNotes(
        transcript: String,
        meetingTitle: String,
        error: Error,
        manualNotes: String? = nil
    ) -> String {
        let writtenNotesSection = optionalNotesSection(
            header: "## Written Notes",
            notes: manualNotes,
            separatesHeaderAndBody: true
        )
        return """
        ## Summary failed

        Meeting: \(meetingTitle)

        Muesli could not generate structured meeting notes.

        \(error.localizedDescription)
        \(writtenNotesSection)

        ## Raw Transcript

        \(transcript)
        """
    }

    private static func generate(backend: MeetingSummaryBackend, model: String, apiKey: String,
                                 systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        if backend == .chatGPT {
            return try await callChatGPT(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model)
        }
        guard !apiKey.isEmpty else { throw MeetingSummaryError.missingCredentials(backend) }
        if backend == .openRouter {
            return try await callChatCompletions(url: openRouterURL, backend: backend.label, apiKey: apiKey,
                model: model, systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens,
                extraHeaders: ["X-OpenRouter-Title": "Muesli"])
        }
        let session = URLSession(configuration: ChatGPTResponsesTransport.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let limit = backend == .anthropic
            ? try await AnthropicSummaryPolicy.maximum(model: model, apiKey: apiKey, session: session)
            : maxTokens
        let request = try publicAPIRequest(backend: backend, model: model, apiKey: apiKey,
                                          systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: limit)
        if backend == .anthropic, limit > 21_333 {
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw MeetingSummaryError.backendFailed(backend: backend.label, statusCode: (response as? HTTPURLResponse)?.statusCode,
                                                       message: "Check your API key and model access, then retry.")
            }
            var stream = AnthropicSummaryStream()
            for try await line in bytes.lines {
                try Task.checkCancellation()
                try stream.consume(line: line)
                if stream.finished { break }
            }
            try Task.checkCancellation()
            return try stream.result()
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try validateHTTPResponse(response, data: data, backend: backend.label)
        return try publicAPIText(data, backend: backend)
    }

    static func publicAPIRequest(backend: MeetingSummaryBackend, model: String, apiKey: String,
                                 systemPrompt: String, userPrompt: String, maxTokens: Int) throws -> URLRequest {
        let anthropic = backend == .anthropic
        let endpoint = anthropic ? "https://api.anthropic.com/v1/messages" : "https://api.openai.com/v1/responses"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        if anthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": maxTokens, "stream": maxTokens > 21_333, "system": systemPrompt,
                    "messages": [["role": "user", "content": userPrompt]]]
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // Avoid arbitrary output caps consuming a reasoning model's whole budget.
            body = ["model": model, "store": false, "instructions": systemPrompt, "input": userPrompt]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func publicAPIText(_ data: Data, backend: MeetingSummaryBackend) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingSummaryError.emptyResponse(backend.label)
        }
        let text: String?
        if backend == .anthropic {
            guard ["end_turn", "stop_sequence"].contains(json["stop_reason"] as? String ?? "") else {
                throw MeetingSummaryError.backendFailed(backend: backend.label, statusCode: nil, message: "The summary was interrupted. Please retry.")
            }
            text = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            guard json["status"] as? String == "completed" else {
                throw MeetingSummaryError.backendFailed(backend: backend.label, statusCode: nil, message: "The summary was interrupted. Please retry.")
            }
            text = SummaryResponseStream.outputText(json)
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            throw MeetingSummaryError.emptyResponse(backend.label)
        }
        return trimmed
    }

    private static func summaryPrompt(
        transcript: String,
        meetingTitle: String,
        manualNotesToRetain: String?,
        template: MeetingTemplatePreset
    ) -> String {
        let manualNotesSection = optionalNotesSection(
            header: "User-written notes to retain:",
            notes: manualNotesToRetain
        )
        return """
        Meeting title: \(meetingTitle)

        Meeting note template: \(template.label)

        Template guidance:
        \(template.instructions)
        \(manualNotesSection)

        Raw transcript:
        \(transcript)
        """
    }

    private static func optionalNotesSection(
        header: String,
        notes: String?,
        separatesHeaderAndBody: Bool = false
    ) -> String {
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedNotes.isEmpty else { return "" }
        let separator = separatesHeaderAndBody ? "\n\n" : "\n"
        return """

        \(header)\(separator)\(trimmedNotes)
        """
    }

    private static func callChatCompletions(
        url: URL,
        backend: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        extraHeaders: [String: String]
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let session = URLSession(configuration: ChatGPTResponsesTransport.sessionConfiguration())
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            try validateHTTPResponse(response, data: data, backend: backend)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = extractChatCompletionsText(from: json),
                  !text.isEmpty else {
                throw MeetingSummaryError.emptyResponse(backend)
            }
            return text
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if error is MeetingSummaryError {
                throw error
            }
            throw MeetingSummaryError.requestFailed(backend: backend, underlying: error)
        }
    }

    private static func callChatGPT(systemPrompt: String, userPrompt: String, model: String) async throws -> String {
        let (token, accountID) = try await ChatGPTAuthManager.shared.validAccessToken()
        try Task.checkCancellation()
        let body: [String: Any] = ["model": model, "store": false, "stream": true, "instructions": systemPrompt,
            "input": [["role": "user", "content": [["type": "input_text", "text": userPrompt]]]] as [[String: Any]]]
        let request = try ChatGPTResponsesTransport.makeRequest(body: body, token: token, accountID: accountID)
        let session = URLSession(configuration: ChatGPTResponsesTransport.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MeetingSummaryError.backendFailed(backend: "ChatGPT", statusCode: (response as? HTTPURLResponse)?.statusCode,
                                                   message: "Please check your ChatGPT access and try again.")
        }
        var stream = SummaryResponseStream()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try stream.consume(line: line)
            if stream.completedText != nil { break }
        }
        try Task.checkCancellation()
        return try stream.result()
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data, backend: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MeetingSummaryError.backendFailed(backend: backend, statusCode: nil, message: "Invalid server response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw MeetingSummaryError.backendFailed(
                backend: backend,
                statusCode: httpResponse.statusCode,
                message: String(message.prefix(800))
            )
        }
    }

    static func extractChatCompletionsText(from payload: [String: Any]) -> String? {
        let choices = payload["choices"] as? [[String: Any]] ?? []
        guard choices.first?["finish_reason"] as? String == "stop",
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content = message["content"] as? [[String: Any]] {
            let parts = content.compactMap { entry -> String? in
                guard (entry["type"] as? String) == "text",
                      let text = entry["text"] as? String else {
                    return nil
                }
                return text
            }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String) ?? String(describing: error)
        }
        return (json["message"] as? String) ?? (json["detail"] as? String)
    }
}

struct MeetingSummaryResult {
    let notes: String
    let title: String
    let backend: MeetingSummaryBackend
    let model: String
}

struct MeetingSummaryConfiguration {
    let backend: MeetingSummaryBackend
    let model: String
    let template: MeetingTemplatePreset
    let apiKey: String

    static func current() -> Self {
        let backend = MuesliPreferences.meetingSummaryBackend
        return Self(backend: backend, model: MuesliPreferences.summaryModel(for: backend),
                    template: MuesliPreferences.meetingTemplate, apiKey: MeetingSummaryClient.storedAPIKey(for: backend))
    }
}
