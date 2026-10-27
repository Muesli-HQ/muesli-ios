import SwiftUI
import UniformTypeIdentifiers

struct AudioImportView: View {
    @Bindable var coordinator: DictationCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Imported audio is saved in Meetings. Audio stays on this iPhone; transcripts follow your sync settings.")
                    TranscriptionModelSelector(selection: $coordinator.selectedTranscriptionModel,
                        downloadedModels: coordinator.downloadedTranscriptionModels,
                        preparation: coordinator.modelPreparation, onSelect: coordinator.selectTranscriptionModel)
                        .disabled(coordinator.isImportingAudio || coordinator.isRecording || coordinator.isMeetingTranscribing || coordinator.hasMeetingRecordingInProgress)
                    ModelReadinessView(state: coordinator.modelPreparation, modelName: coordinator.selectedTranscriptionModel.shortName, retry: coordinator.prepareModel)
                }
                ForEach(coordinator.pendingAudioImports) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.title).font(.headline)
                        Button("Import and Transcribe") { coordinator.importAudio(item) }
                            .disabled(!coordinator.canImportAudio)
                        Button("Remove", role: .destructive) { coordinator.dismissAudioImport(item) }
                            .disabled(coordinator.isImportingAudio)
                    }
                }
                if coordinator.isImportingAudio {
                    ProgressView("Importing audio…")
                    Button("Cancel Import", role: .cancel) { coordinator.cancelAudioImport() }
                }
                if let error = coordinator.audioImportError { Text(error).foregroundStyle(.red) }
            }
            .interactiveDismissDisabled(coordinator.isImportingAudio)
            .navigationTitle("Import Audio")
            .toolbar { Button("Done") { dismiss() }.disabled(coordinator.isImportingAudio) }
            .onAppear { coordinator.ensureModelReadyForRecording() }
        }
    }
}
