import SwiftUI

struct SummaryAPISettingsView: View {
    let backend: MeetingSummaryBackend
    @State private var apiKey: String
    @State private var model: String
    @State private var saveError: String?

    init(backend: MeetingSummaryBackend) {
        self.backend = backend
        _apiKey = State(initialValue: MeetingSummaryClient.storedAPIKey(for: backend))
        _model = State(initialValue: MuesliPreferences.summaryModel(for: backend))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsTextFieldRow(icon: "key", title: "\(backend.label) API Key", placeholder: "API key", text: $apiKey, isSecure: true)
            SettingsModelPickerRow(icon: "cpu", title: "Model", selection: $model, presets: backend.presets)
            Text("Transcripts are sent to \(backend.label) for summaries. API usage is billed separately.")
                .font(.footnote).foregroundStyle(.secondary)
            if let saveError { Text(saveError).font(.footnote).foregroundStyle(.red) }
        }
        .onChange(of: apiKey) { _, value in
            do { try MeetingSummaryClient.saveAPIKey(value, for: backend); saveError = nil }
            catch { saveError = error.localizedDescription }
        }
        .onChange(of: model) { _, value in
            UserDefaults.standard.set(value, forKey: backend.modelPreferenceKey)
        }
    }
}
