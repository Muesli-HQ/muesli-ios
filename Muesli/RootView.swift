import SwiftUI

struct RootView: View {
    @Bindable var coordinator: DictationCoordinator
    @State private var selectedSection: AppSection = .dictate

    var body: some View {
        Group {
            if coordinator.hasCompletedOnboarding {
                VStack(spacing: 0) {
                    Group {
                        switch selectedSection {
                        case .dictate:
                            DictationView(coordinator: coordinator)
                        case .settings:
                            SettingsView(coordinator: coordinator)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    MuesliTabSwitcher(selectedSection: $selectedSection)
                        .padding(.horizontal, MuesliTheme.spacing20)
                        .padding(.bottom, MuesliTheme.spacing12)
                        .padding(.top, MuesliTheme.spacing8)
                        .background(MuesliTheme.backgroundBase)
                }
            } else {
                OnboardingView(coordinator: coordinator)
            }
        }
        .background(MuesliTheme.backgroundBase)
        .tint(MuesliTheme.accent)
    }
}

private enum AppSection: String, CaseIterable {
    case dictate
    case settings

    var title: String {
        switch self {
        case .dictate:
            "Dictate"
        case .settings:
            "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dictate:
            "mic.fill"
        case .settings:
            "gearshape.fill"
        }
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
