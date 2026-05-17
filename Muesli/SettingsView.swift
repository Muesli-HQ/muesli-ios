import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: DictationCoordinator
    @AppStorage(MuesliPreferences.liveActivitiesForDictationsKey) private var liveActivitiesForDictations = true
    @AppStorage(MuesliPreferences.liveActivitiesForMeetingsKey) private var liveActivitiesForMeetings = true
    @AppStorage(MuesliPreferences.keyboardSessionModeKey) private var keyboardSessionMode = false
    @AppStorage(MuesliPreferences.keyboardSessionTimeoutMinutesKey) private var keyboardSessionTimeoutMinutes = 10
    @State private var keyboardStatusText = "Unknown"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    settingsHeader

                    MuesliSurface {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            SettingsRow(icon: "keyboard", title: "Keyboard", value: keyboardStatusText)
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
                            SettingsToggleRow(
                                icon: "keyboard.badge.ellipsis",
                                title: "Keyboard Session Mode",
                                detail: "Keep Muesli ready for keyboard dictation with a visible microphone session.",
                                isOn: $keyboardSessionMode
                            )
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            SettingsRow(
                                icon: "waveform.badge.mic",
                                title: "Session",
                                value: coordinator.keyboardSessionStatusText
                            )
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            Stepper(value: $keyboardSessionTimeoutMinutes, in: 1...30, step: 1) {
                                SettingsRow(
                                    icon: "timer",
                                    title: "Timeout",
                                    value: "\(keyboardSessionTimeoutMinutes) min"
                                )
                            }
                            .disabled(!keyboardSessionMode)
                        }
                        .padding(MuesliTheme.spacing16)
                    }

                    MuesliSurface {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            SettingsToggleRow(
                                icon: "waveform.badge.mic",
                                title: "Dictation Live Activities",
                                detail: "Show keyboard and in-app dictation progress on the Dynamic Island and Lock Screen.",
                                isOn: $liveActivitiesForDictations
                            )
                            Divider().overlay(MuesliTheme.surfaceBorder)
                            SettingsToggleRow(
                                icon: "person.2.wave.2",
                                title: "Meeting Live Activities",
                                detail: "Show active meeting recordings while Muesli is recording in the background.",
                                isOn: $liveActivitiesForMeetings
                            )
                        }
                        .padding(MuesliTheme.spacing16)
                    }
                }
                .padding(MuesliTheme.spacing20)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                refreshKeyboardStatus()
            }
            .onChange(of: liveActivitiesForDictations) { _, _ in
                coordinator.applyLiveActivityPreferences()
            }
            .onChange(of: liveActivitiesForMeetings) { _, _ in
                coordinator.applyLiveActivityPreferences()
            }
            .onChange(of: keyboardSessionMode) { _, enabled in
                coordinator.setKeyboardSessionModeEnabled(enabled)
            }
            .onChange(of: keyboardSessionTimeoutMinutes) { _, _ in
                coordinator.refreshKeyboardSessionTimeout()
            }
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

    private func refreshKeyboardStatus() {
        let store = SharedStore()
        let extensionStatus = try? store.keyboardExtensionStatus()
        let confirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.keyboardEnabledConfirmed)
        let fullAccessConfirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.fullAccessConfirmed)

        if extensionStatus?.hasOpenAccess == true {
            keyboardStatusText = "Enabled"
        } else if confirmed && fullAccessConfirmed {
            keyboardStatusText = "Needs first use"
        } else if confirmed {
            keyboardStatusText = "Full Access needed"
        } else {
            keyboardStatusText = "Not confirmed"
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

private struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(MuesliTheme.accent)
        }
    }
}
