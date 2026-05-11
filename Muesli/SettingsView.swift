import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Keyboard") {
                    Link("Open Keyboard Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    Text("Enable Muesli Keyboard and Allow Full Access so the keyboard can exchange dictation state through the App Group container.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Models") {
                    LabeledContent("Engine", value: "Not configured")
                    LabeledContent("Runtime", value: "CoreML / ANE")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

