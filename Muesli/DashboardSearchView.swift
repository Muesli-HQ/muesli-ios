import SwiftUI

enum HistoryRecordID: Hashable, Sendable {
    case result(UUID)
    case session(UUID)
}

private extension DictationResult {
    func searchKind(session: RecordingSession?) -> String {
        if session?.kind == .keyboardDictation || source == "keyboard" || syncOrigin == .fromMac {
            return "Dictation"
        }
        return "Voice Note"
    }
}

struct HistorySearchMatch: Identifiable, Sendable {
    let id: HistoryRecordID
    let kind: String
    let title: String
    let date: Date
    let excerpt: String
}

struct HistorySearchInput: Equatable, Sendable {
    let query: String
    let history: [DictationResult]
    let sessions: [RecordingSession]
    let transcripts: [UUID: Transcript]

    func matches() async throws -> [HistorySearchMatch] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var represented = Set<UUID>()
        var matches: [HistorySearchMatch] = []

        func append(_ id: HistoryRecordID, kind: String, title: String?, date: Date, fields: [String?]) {
            for field in [title] + fields {
                guard let field, let range = field.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                let start = field.index(range.lowerBound, offsetBy: -36, limitedBy: field.startIndex) ?? field.startIndex
                let end = field.index(range.lowerBound, offsetBy: 144, limitedBy: field.endIndex) ?? field.endIndex
                let excerpt = (start == field.startIndex ? "" : "…") + field[start..<end] + (end == field.endIndex ? "" : "…")
                matches.append(.init(id: id, kind: kind, title: title ?? kind, date: date, excerpt: String(excerpt)))
                return
            }
        }

        for result in history {
            try Task.checkCancellation()
            let session = result.sessionID.flatMap { sessionsByID[$0] }
            if let session { represented.insert(session.id) }
            append(.result(result.id), kind: result.searchKind(session: session), title: session?.title,
                   date: result.createdAt, fields: [result.text, session?.scratchpadText, session?.manualNotes])
        }
        for session in sessions where session.kind == .meeting || !represented.contains(session.id) {
            try Task.checkCancellation()
            let transcript = transcripts[session.id]
            let kind = session.kind == .meeting ? "Meeting" : session.kind == .keyboardDictation ? "Dictation" : "Voice Note"
            append(.session(session.id), kind: kind, title: session.title, date: session.createdAt,
                   fields: [session.manualNotes, session.scratchpadText, transcript?.summaryText, transcript?.text, transcript?.speakerTranscript])
        }
        return matches.sorted { $0.date > $1.date }
    }
}

struct DashboardSearchView: View {
    let coordinator: DictationCoordinator
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var query = ""
    @State private var results: [HistorySearchMatch] = []
    @State private var completedQuery: String?
    @State private var path: [HistoryRecordID] = []

    var body: some View {
        let input = HistorySearchInput(query: query, history: coordinator.dictationHistory,
                                       sessions: coordinator.recordingSessions, transcripts: coordinator.transcriptCache)
        NavigationStack(path: $path) {
            VStack {
                TextField("Search notes, dictations, and meetings", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                    .padding(.horizontal)
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if completedQuery != query {
                        ProgressView()
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        List(results) { match in
                            NavigationLink(value: match.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(match.title).font(MuesliTheme.headline())
                                    if match.excerpt != match.title { Text(match.excerpt).lineLimit(2) }
                                    Text((match.title == match.kind ? "" : match.kind + " · ") + match.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(MuesliTheme.caption()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
                Spacer(minLength: 0)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: HistoryRecordID.self) { id in
                destination(id)
            }
        }
        .onAppear { isFocused = true }
        .task(id: input) {
            do {
                if !input.query.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                let found = try await input.matches()
                try Task.checkCancellation()
                results = found
                completedQuery = input.query
            } catch { /* A newer search or dismissal cancelled this search. */ }
        }
    }

    @ViewBuilder
    private func destination(_ id: HistoryRecordID) -> some View {
        switch id {
        case .session(let key):
            if let session = coordinator.recordingSessions.first(where: { $0.id == key }) {
                if session.kind == .meeting {
                    MeetingHistoryDestination(coordinator: coordinator, sessionID: key) { path.removeAll() }
                } else {
                    textDetail(title: session.title ?? session.kind.title,
                               fields: [session.scratchpadText, session.manualNotes, coordinator.transcript(for: session)?.text])
                }
            } else { missing }
        case .result(let key):
            if let result = coordinator.dictationHistory.first(where: { $0.id == key }) {
                let session = coordinator.recordingSession(for: result)
                if let session, session.scratchpadText == nil, session.manualNotes == nil,
                   let url = coordinator.audioFileURL(for: result) {
                    DictationAudioDetailView(result: result, session: session, audioURL: url) {
                        coordinator.copyToClipboard(result)
                    } onDeleteAudio: { coordinator.deleteDictationAudio(for: result) }
                } else {
                    textDetail(title: session?.title ?? result.searchKind(session: session),
                               fields: [result.text, session?.scratchpadText, session?.manualNotes])
                }
            } else { missing }
        }
    }

    private func textDetail(title: String, fields: [String?]) -> some View {
        var seen = Set<String>()
        let paragraphs = fields.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return ScrollView {
            Text(paragraphs.joined(separator: "\n\n")).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle(title)
    }

    private var missing: some View {
        ContentUnavailableView("Record unavailable", systemImage: "doc")
    }
}
