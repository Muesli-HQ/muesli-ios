import SwiftUI

struct RootView: View {
    @Bindable var coordinator: DictationCoordinator
    @State private var selectedSection: AppSection = .dictations
    @State private var isDrawerOpen = false
    @AppStorage(MuesliPreferences.appearanceModeKey) private var appearanceMode = MuesliAppearanceMode.system.rawValue
    @AppStorage(MuesliPreferences.accentThemeKey) private var accentTheme = MuesliAccentTheme.blue.rawValue
    @AppStorage(MuesliPreferences.pinnedSectionsKey) private var pinnedSectionsStorage = AppSection.defaultPinnedStorage

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
        .tint(currentAccent)
        .environment(\.muesliAccent, currentAccent)
        .preferredColorScheme(preferredColorScheme)
        .onChange(of: coordinator.syncSetupRequestID) { _, requestID in
            navigateToSettingsIfNeeded(requestID)
        }
        .onChange(of: coordinator.settingsNavigationRequestID) { _, requestID in
            navigateToSettingsIfNeeded(requestID)
        }
        .onChange(of: pinnedSectionsStorage) { _, _ in
            clampSelectedSectionToPinnedSections()
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { coordinator.presentedLongVoiceNoteSessionID != nil },
                set: { isPresented in
                    if !isPresented {
                        coordinator.dismissLongVoiceNote()
                    }
                }
            )
        ) {
            if let sessionID = coordinator.presentedLongVoiceNoteSessionID {
                LongVoiceNoteView(coordinator: coordinator, sessionID: sessionID)
            }
        }
    }

    private var currentAccent: Color {
        MuesliTheme.color(for: MuesliAccentTheme.resolved(rawValue: accentTheme))
    }

    private var preferredColorScheme: ColorScheme? {
        switch MuesliAppearanceMode(rawValue: appearanceMode) ?? .system {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    @ViewBuilder
    private var appShell: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                HStack(spacing: 0) {
                    MuesliSidebar(
                        selectedSection: $selectedSection,
                        pinnedSections: pinnedSections,
                        onTogglePin: togglePinnedSection
                    )
                        .frame(width: 238)

                    Divider()
                        .background(MuesliTheme.surfaceBorder)

                    sectionContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(MuesliTheme.backgroundBase)
            } else {
                VStack(spacing: 0) {
                    pagedSectionContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    MuesliTabSwitcher(
                        selectedSection: $selectedSection,
                        pinnedSections: pinnedSections
                    )
                        .padding(.horizontal, MuesliTheme.Navigation.horizontalInset)
                        .padding(.bottom, MuesliTheme.spacing8)
                        .padding(.top, MuesliTheme.spacing4)
                        .background(MuesliTheme.backgroundBase)
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: openDrawer) {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .frame(width: 44, height: 44)
                            .muesliGlassButton(cornerRadius: 22, tint: currentAccent)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, MuesliTheme.spacing20)
                    .padding(.top, MuesliTheme.spacing24)
                    .opacity(isDrawerOpen ? 0 : 1)
                    .accessibilityLabel("Open sidebar")
                }
                .overlay {
                    CompactSidebarOverlay(
                        isOpen: $isDrawerOpen,
                        selectedSection: $selectedSection,
                        pinnedSections: pinnedSections,
                        onTogglePin: togglePinnedSection
                    )
                }
                .contentShape(Rectangle())
            }
        }
    }

    private var pinnedSections: [AppSection] {
        AppSection.pinnedSections(from: pinnedSectionsStorage)
    }

    @ViewBuilder
    private var sectionContent: some View {
        sectionView(for: selectedSection, isActive: true)
    }

    @ViewBuilder
    private func sectionView(for section: AppSection, isActive: Bool) -> some View {
        switch section {
        case .dictations:
            DictationView(coordinator: coordinator, isActive: isActive)
        case .meetings:
            MeetingsView(coordinator: coordinator, isActive: isActive)
        case .settings:
            SettingsView(
                coordinator: coordinator,
                openSyncPrivacyRequest: coordinator.syncSetupRequestID,
                openInputRequest: coordinator.inputSettingsNavigationRequestID,
                isActive: isActive
            ) { section in
                selectedSection = section
            }
        }
    }

    private var pagedSectionContent: some View {
        TabView(selection: $selectedSection) {
            ForEach(pageSections, id: \.self) { section in
                sectionView(for: section, isActive: selectedSection == section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(section)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var pageSections: [AppSection] {
        var sections = pinnedSections
        if !sections.contains(selectedSection) {
            sections.append(selectedSection)
        }
        return sections
    }

    private func openDrawer() {
        withAnimation(.snappy(duration: 0.24)) {
            isDrawerOpen = true
        }
    }

    private func closeDrawer() {
        withAnimation(.snappy(duration: 0.24)) {
            isDrawerOpen = false
        }
    }

    private func navigateToSettingsIfNeeded(_ requestID: UUID?) {
        guard requestID != nil else { return }
        if coordinator.hasCompletedOnboarding {
            selectedSection = .settings
        }
        isDrawerOpen = false
    }

    private func togglePinnedSection(_ section: AppSection) {
        var pins = pinnedSections
        if pins.contains(section) {
            guard pins.count > 1 else { return }
            pins.removeAll { $0 == section }
        } else {
            if pins.count >= AppSection.maxPinnedSections {
                pins.removeFirst()
            }
            pins.append(section)
        }
        pinnedSectionsStorage = AppSection.storageString(for: pins)
        if !pins.contains(selectedSection), let nextSection = pins.first {
            selectedSection = nextSection
        }
    }

    private func clampSelectedSectionToPinnedSections() {
        let pins = pinnedSections
        if !pins.contains(selectedSection), let nextSection = pins.first {
            selectedSection = nextSection
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
                    MuesliInlineWaveformView(
                        mode: coordinator.isRecording ? .level : .waiting,
                        color: coordinator.isRecording ? MuesliTheme.recording : MuesliTheme.transcribing,
                        level: coordinator.isRecording ? coordinator.inputLevel : nil,
                        barCount: 32
                    )
                    .frame(width: 220, height: 56)

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

                    Text("Keep Muesli recording in the background, then tap Stop on the Muesli keyboard. The transcript will insert into the focused text box.")
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
                    .muesliGlassSurface(
                        cornerRadius: MuesliTheme.cornerMedium,
                        tint: coordinator.isRecording ? MuesliTheme.recording : MuesliTheme.transcribing
                    )
            }
            .padding(MuesliTheme.spacing24)
        }
    }
}

enum AppSection: String, CaseIterable {
    case dictations
    case meetings
    case settings

    static let maxPinnedSections = 3
    static let defaultPinnedSections: [AppSection] = [.dictations, .meetings, .settings]
    static let defaultPinnedStorage = storageString(for: defaultPinnedSections)

    var title: String {
        switch self {
        case .dictations:
            "Voice Notes"
        case .meetings:
            "Meetings"
        case .settings:
            "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dictations:
            "waveform"
        case .meetings:
            "person.2.wave.2"
        case .settings:
            "gearshape.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .dictations:
            "Quick voice notes"
        case .meetings:
            "Record and summarize"
        case .settings:
            "Preferences"
        }
    }

    static func pinnedSections(from storage: String) -> [AppSection] {
        let sections = storage
            .split(separator: ",")
            .compactMap { AppSection(rawValue: String($0)) }
            .reduce(into: [AppSection]()) { result, section in
                if !result.contains(section), result.count < maxPinnedSections {
                    result.append(section)
                }
            }
        return sections.isEmpty ? defaultPinnedSections : sections
    }

    static func storageString(for sections: [AppSection]) -> String {
        sections.prefix(maxPinnedSections).map(\.rawValue).joined(separator: ",")
    }
}

private struct MuesliSidebar: View {
    @Binding var selectedSection: AppSection
    let pinnedSections: [AppSection]
    let onTogglePin: (AppSection) -> Void

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
            .padding(.top, MuesliTheme.spacing32)

            VStack(spacing: MuesliTheme.spacing4) {
                ForEach(AppSection.allCases, id: \.self) { section in
                    SidebarSectionRow(
                        section: section,
                        isSelected: selectedSection == section,
                        isPinned: pinnedSections.contains(section),
                        canUnpin: pinnedSections.count > 1,
                        onSelect: { selectedSection = section },
                        onTogglePin: { onTogglePin(section) }
                    )
                }
            }
            .padding(.horizontal, MuesliTheme.spacing12)

            Spacer()
        }
        .background(MuesliTheme.backgroundDeep)
    }
}

private struct MuesliTabSwitcher: View {
    @Environment(\.muesliAccent) private var accent
    @Binding var selectedSection: AppSection
    let pinnedSections: [AppSection]
    @Namespace private var glassNamespace

    var body: some View {
        MuesliGlassGroup(spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.Navigation.itemSpacing) {
                ForEach(pinnedSections, id: \.self) { section in
                    let isSelected = selectedSection == section

                    Button {
                        withAnimation(.snappy(duration: 0.24, extraBounce: 0.05)) {
                            selectedSection = section
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: section.icon)
                                .font(.system(size: 17, weight: .semibold))
                                .symbolRenderingMode(.monochrome)
                                .frame(height: 20)

                            Text(section.title)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                            .foregroundStyle(isSelected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: MuesliTheme.Navigation.itemHeight)
                            .muesliNavigationSelection(
                                isSelected: isSelected,
                                tint: accent,
                                namespace: glassNamespace
                            )
                            .contentShape(
                                RoundedRectangle(
                                    cornerRadius: MuesliTheme.Navigation.selectionCornerRadius,
                                    style: .continuous
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("tab.\(section.rawValue)")
                }
            }
            .padding(MuesliTheme.Navigation.containerPadding)
            .muesliNavigationGlassSurface(
                cornerRadius: MuesliTheme.Navigation.containerCornerRadius
            )
        }
    }
}

private struct CompactSidebarOverlay: View {
    @Binding var isOpen: Bool
    @Binding var selectedSection: AppSection
    let pinnedSections: [AppSection]
    let onTogglePin: (AppSection) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if isOpen {
                MuesliTheme.backgroundBase.opacity(0.58)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                    .transition(.opacity)
            }

            MuesliDrawer(
                selectedSection: $selectedSection,
                pinnedSections: pinnedSections,
                onTogglePin: onTogglePin,
                onClose: close
            )
            .frame(width: 312)
            .offset(x: isOpen ? 0 : -328)
            .opacity(isOpen ? 1 : 0)
        }
        .allowsHitTesting(isOpen)
        .animation(.snappy(duration: 0.24), value: isOpen)
    }

    private func close() {
        withAnimation(.snappy(duration: 0.24)) {
            isOpen = false
        }
    }
}

private struct MuesliDrawer: View {
    @Binding var selectedSection: AppSection
    let pinnedSections: [AppSection]
    let onTogglePin: (AppSection) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image("MuesliAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("muesli")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Pin up to 3 sections")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .frame(width: 44, height: 44)
                            .muesliGlassButton(cornerRadius: 22)
                            .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.top, MuesliTheme.spacing32)

            VStack(spacing: MuesliTheme.spacing4) {
                ForEach(AppSection.allCases, id: \.self) { section in
                    SidebarSectionRow(
                        section: section,
                        isSelected: selectedSection == section,
                        isPinned: pinnedSections.contains(section),
                        canUnpin: pinnedSections.count > 1,
                        onSelect: {
                            selectedSection = section
                            onClose()
                        },
                        onTogglePin: { onTogglePin(section) }
                    )
                }
            }
            .padding(.horizontal, MuesliTheme.spacing12)

            Spacer()
        }
        .background(MuesliTheme.backgroundDeep)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(MuesliTheme.surfaceBorder)
                .frame(width: 1)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct SidebarSectionRow: View {
    @Environment(\.muesliAccent) private var accent
    let section: AppSection
    let isSelected: Bool
    let isPinned: Bool
    let canUnpin: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Button(action: onSelect) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(MuesliTheme.headline())
                        Text(section.subtitle)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                } icon: {
                    Image(systemName: section.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22)
                }
                .foregroundStyle(isSelected ? accent : MuesliTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 52)
                .padding(.leading, MuesliTheme.spacing12)
                .background(isSelected ? accent.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isPinned ? accent : MuesliTheme.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(isPinned ? accent.opacity(0.15) : Color.clear)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isPinned && !canUnpin)
            .opacity(isPinned && !canUnpin ? 0.45 : 1)
            .accessibilityLabel(isPinned ? "Unpin \(section.title)" : "Pin \(section.title)")
        }
    }
}

private struct MeetingTemplatesView: View {
    @AppStorage(MuesliPreferences.meetingTemplateKey) private var meetingTemplate = MeetingTemplatePreset.general.rawValue

    private var selectedTemplate: MeetingTemplatePreset {
        MeetingTemplatePreset(rawValue: meetingTemplate) ?? .general
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Templates")
                            .font(MuesliTheme.title1())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text("Choose how Muesli structures generated meeting notes.")
                            .font(MuesliTheme.callout())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVStack(spacing: MuesliTheme.spacing12) {
                        ForEach(MeetingTemplatePreset.allCases) { template in
                            Button {
                                meetingTemplate = template.rawValue
                                AppTelemetry.signal("meeting_template_selected", parameters: [
                                    "template": template.rawValue,
                                    "source": "templates"
                                ])
                            } label: {
                                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                                    Image(systemName: selectedTemplate == template ? "checkmark.circle.fill" : "doc.text")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(selectedTemplate == template ? MuesliTheme.success : MuesliTheme.accent)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                                        Text(template.label)
                                            .font(MuesliTheme.headline())
                                            .foregroundStyle(MuesliTheme.textPrimary)
                                        Text(template.detail)
                                            .font(MuesliTheme.body())
                                            .foregroundStyle(MuesliTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    Spacer()
                                }
                                .padding(MuesliTheme.spacing16)
                                .background(selectedTemplate == template ? MuesliTheme.surfaceSelected : MuesliTheme.backgroundRaised)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                .overlay(
                                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                        .strokeBorder(selectedTemplate == template ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.top, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing24)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
