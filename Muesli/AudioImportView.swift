import SwiftUI
import UniformTypeIdentifiers

struct AudioImportView: View {
    @Bindable var coordinator: DictationCoordinator
    @State private var showsPicker = false
    @State private var destinations: [UUID: AudioImportDestination] = [:]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TranscriptionModelSelector(selection: $coordinator.selectedTranscriptionModel,
                        downloadedModels: coordinator.downloadedTranscriptionModels, showsHeader: false, compact: true,
                        preparation: coordinator.modelPreparation, onSelect: coordinator.selectTranscriptionModel)
                        .disabled(coordinator.isImportingAudio || coordinator.isRecording || coordinator.isMeetingTranscribing || coordinator.hasMeetingRecordingInProgress)
                    ModelReadinessView(state: coordinator.modelPreparation, modelName: coordinator.selectedTranscriptionModel.shortName, retry: coordinator.prepareModel)
                }
                ForEach(coordinator.pendingAudioImports) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.title).font(MuesliTheme.headline())
                        Picker("Save as", selection: Binding(
                            get: { destinations[item.id] ?? .voiceNote },
                            set: { destinations[item.id] = $0 }
                        )) {
                            Text("Voice Note").tag(AudioImportDestination.voiceNote)
                            Text("Meeting").tag(AudioImportDestination.meeting)
                        }
                        .pickerStyle(.segmented)
                        .disabled(coordinator.isImportingAudio)
                        Button { coordinator.importAudio(item, destination: destinations[item.id] ?? .voiceNote) } label: {
                            Text("Transcribe")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(MuesliPrimaryButtonStyle())
                        .disabled(!coordinator.canImportAudio)
                        Button("Remove", role: .destructive) { coordinator.dismissAudioImport(item) }
                            .buttonStyle(.borderless)
                            .disabled(coordinator.isImportingAudio)
                    }
                }
                if coordinator.isImportingAudio {
                    ProgressView("Importing audio…")
                    Button("Cancel Import", role: .cancel) { coordinator.cancelAudioImport() }
                }
                if let error = coordinator.audioImportError {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if let details = coordinator.audioImportErrorDetails {
                            DisclosureGroup("Error Details") { Text(details).font(MuesliTheme.caption()).textSelection(.enabled) }
                        }
                        Button("Choose Another File") { showsPicker = true }
                    }
                }
                if coordinator.pendingAudioImports.isEmpty && coordinator.audioImportError == nil {
                    Text("No audio waiting to import.").foregroundStyle(.secondary)
                }
            }
            .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.audio, .mpeg4Movie]) { result in
                switch result {
                case .success(let url): coordinator.audioImportError = nil; coordinator.receiveAudioFile(url)
                case .failure(let error): coordinator.reportAudioImportError(error, stage: "Choose file")
                }
            }
            .interactiveDismissDisabled(coordinator.isImportingAudio)
            .navigationTitle("Import Audio")
            .toolbar { Button("Done") { dismiss() }.disabled(coordinator.isImportingAudio) }
            .onAppear { coordinator.ensureModelReadyForRecording() }
        }
    }
}
