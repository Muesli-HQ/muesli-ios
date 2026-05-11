import SwiftUI

struct DictationView: View {
    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: coordinator.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(coordinator.isRecording ? .red : .accentColor)

                    Text(coordinator.statusText)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }

                Button {
                    coordinator.toggleRecording()
                } label: {
                    Label(coordinator.isRecording ? "Stop" : "Start", systemImage: coordinator.isRecording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !coordinator.lastTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latest Transcript")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(coordinator.lastTranscript)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Muesli")
        }
    }
}
