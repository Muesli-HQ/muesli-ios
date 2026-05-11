import SwiftUI

struct RootView: View {
    @Bindable var coordinator: DictationCoordinator
    @State private var selectedSection: AppSection = .dictations

    var body: some View {
        Group {
            if coordinator.hasCompletedOnboarding {
                appShell
            } else {
                OnboardingView(coordinator: coordinator)
            }
        }
        .overlay {
            if coordinator.isKeyboardHandoffActive {
                KeyboardHandoffOverlay(coordinator: coordinator)
            }
        }
        .background(MuesliTheme.backgroundBase)
        .tint(MuesliTheme.accent)
    }

    @ViewBuilder
    private var appShell: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                HStack(spacing: 0) {
                    MuesliSidebar(selectedSection: $selectedSection)
                        .frame(width: 238)

                    Divider()
                        .background(MuesliTheme.surfaceBorder)

                    sectionContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(MuesliTheme.backgroundBase)
            } else {
                VStack(spacing: 0) {
                    sectionContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    MuesliTabSwitcher(selectedSection: $selectedSection)
                        .padding(.horizontal, MuesliTheme.spacing20)
                        .padding(.bottom, MuesliTheme.spacing12)
                        .padding(.top, MuesliTheme.spacing8)
                        .background(MuesliTheme.backgroundBase)
                }
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .dictations:
            DictationView(coordinator: coordinator)
        case .settings:
            SettingsView(coordinator: coordinator)
        }
    }
}

private struct KeyboardHandoffOverlay: View {
    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        ZStack {
            MuesliTheme.backgroundBase
                .ignoresSafeArea()

            VStack(spacing: MuesliTheme.spacing32) {
                Spacer(minLength: MuesliTheme.spacing32)

                VStack(spacing: MuesliTheme.spacing16) {
                    MuesliWaveformView(
                        isActive: coordinator.isRecording,
                        color: coordinator.isRecording ? MuesliTheme.recording : MuesliTheme.transcribing,
                        level: coordinator.isRecording ? coordinator.inputLevel : nil,
                        barCount: 13,
                        spacing: 4
                    )
                    .frame(width: 148, height: 46)

                    Text(coordinator.isRecording ? "Listening" : "Transcribing")
                        .font(MuesliTheme.title2())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    Text(coordinator.isRecording ? "iPhone Microphone" : "Preparing text for the keyboard")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                VStack(spacing: MuesliTheme.spacing12) {
                    Text("Swipe back to your app")
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Keep Muesli recording in the background, then tap Stop Dictation on the Muesli keyboard. The transcript will insert into the focused text box.")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Label("Use the app switcher or swipe gesture to return", systemImage: "arrow.left.arrow.right")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(MuesliTheme.backgroundRaised)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .padding(MuesliTheme.spacing24)
        }
    }
}

private enum AppSection: String, CaseIterable {
    case dictations
    case settings

    var title: String {
        switch self {
        case .dictations:
            "Dictations"
        case .settings:
            "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dictations:
            "waveform"
        case .settings:
            "gearshape.fill"
        }
    }
}

private struct MuesliSidebar: View {
    @Binding var selectedSection: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image("MuesliAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                Text("muesli")
                    .font(MuesliTheme.title3())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.top, MuesliTheme.spacing20)

            VStack(spacing: MuesliTheme.spacing4) {
                ForEach(AppSection.allCases, id: \.self) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.title, systemImage: section.icon)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(selectedSection == section ? MuesliTheme.accent : MuesliTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 42)
                            .padding(.horizontal, MuesliTheme.spacing12)
                            .background(selectedSection == section ? MuesliTheme.surfaceSelected : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MuesliTheme.spacing12)

            Spacer()
        }
        .background(MuesliTheme.backgroundDeep)
    }
}

private struct MuesliTabSwitcher: View {
    @Binding var selectedSection: AppSection

    var body: some View {
        HStack(spacing: MuesliTheme.spacing4) {
            ForEach(AppSection.allCases, id: \.self) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Image(systemName: section.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(section.title)
                            .font(MuesliTheme.headline())
                    }
                    .foregroundStyle(selectedSection == section ? MuesliTheme.accent : MuesliTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(selectedSection == section ? MuesliTheme.surfaceSelected : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(MuesliTheme.spacing8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }
}
