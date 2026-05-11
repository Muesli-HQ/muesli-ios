import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    settingsHeader

                    MuesliSurface {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            SettingsRow(icon: "keyboard", title: "Keyboard", value: "Not enabled")
                            Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                                HStack {
                                    Text("Open Keyboard Settings")
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(MuesliTheme.headline())
                                .foregroundStyle(MuesliTheme.accent)
                                .padding(.top, MuesliTheme.spacing4)
                            }
                        }
                        .padding(MuesliTheme.spacing16)
                    }

                    MuesliSurface {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            SettingsRow(icon: "cpu", title: "Runtime", value: "CoreML / ANE")
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            SettingsRow(icon: "waveform", title: "Engine", value: "Parakeet v3")
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            SettingsRow(icon: "checkmark.seal", title: "Model", value: modelStatus)
                        }
                        .padding(MuesliTheme.spacing16)
                    }
                }
                .padding(MuesliTheme.spacing20)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text("Settings")
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Configure the keyboard shell and local model runtime.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private var modelStatus: String {
        switch coordinator.modelPreparation.phase {
        case .ready:
            "Ready"
        case .downloading:
            "Downloading"
        case .preparing:
            "Preparing"
        case .failed:
            "Paused"
        case .idle:
            "Not prepared"
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)
            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Text(value)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
    }
}
