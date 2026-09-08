import ActivityKit
import AVFoundation
import SwiftUI
import UIKit
import UserNotifications

struct ActionButtonOnboardingView: View {
    @Bindable var coordinator: DictationCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(MuesliPreferences.actionButtonOnboardingCompletedKey) private var setupCompleted = false
    @AppStorage(MuesliPreferences.actionButtonSelectedModeKey) private var selectedMode = ActionButtonCaptureMode.dictation.rawValue
    @AppStorage(MuesliPreferences.actionButtonDeliveryKey) private var delivery = "automatic"
    @AppStorage(MuesliPreferences.liveActivitiesForDictationsKey) private var dictationActivities = true
    @AppStorage(MuesliPreferences.liveActivitiesForMeetingsKey) private var meetingActivities = true
    @AppStorage("actionButton.guidedSetup.step.v1") private var savedStep = 0
    @AppStorage("actionButton.guidedSetup.importOpened.v1") private var importOpened = false
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var notificationsEnabled = false
    @State private var showFileSharing = false
    @AppStorage("actionButton.guidedSetup.settingsOpened.v1") private var settingsOpened = false
    @State private var openingImport = false

    private var mode: ActionButtonCaptureMode { ActionButtonCaptureMode(rawValue: selectedMode) ?? .dictation }
    private var step: ActionButtonSetupStep { ActionButtonSetupStep(rawValue: savedStep) ?? .choose }
    private var tint: Color { mode == .dictation ? MuesliTheme.accent : MuesliTheme.syncGreen }
    private var shortcutName: String {
        mode == .dictation
            ? (MuesliAppConstants.bundleIdentifier.hasSuffix(".dev") ? "MuesliDev Dictation to Clipboard" : "Muesli Dictation to Clipboard")
            : mode.shortcutTitle
    }
    private var shortcutURL: URL? { Bundle.main.url(forResource: shortcutName, withExtension: "shortcut") }
    private var microphoneReady: Bool { microphoneStatus == .authorized }
    private var liveActivityReady: Bool {
        (mode == .dictation ? dictationActivities : meetingActivities) && ActivityAuthorizationInfo().areActivitiesEnabled
    }
    private var captureReady: Bool { microphoneReady && liveActivityReady && coordinator.selectedTranscriptionModel.isDownloaded }
    private var visibleSteps: [ActionButtonSetupStep] { mode == .dictation ? [.choose, .prepare, .add, .assign] : [.choose, .prepare, .assign] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image("MuesliAppIcon").resizable().scaledToFit().frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("muesli").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Close setup")
            }.padding(.horizontal, 24).padding(.top, 8)
            HStack(spacing: 8) {
                ForEach(visibleSteps, id: \.rawValue) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? tint : MuesliTheme.backgroundHover).frame(height: 3)
                }
            }.padding(24)
                .accessibilityLabel("Step \((visibleSteps.firstIndex(of: step) ?? 0) + 1) of \(visibleSteps.count)")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Color.clear.frame(height: 0).id("top")
                        content
                        if dynamicTypeSize.isAccessibilitySize { footer }
                    }.frame(maxWidth: 560, alignment: .leading)
                        .padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity)
                }.onChange(of: savedStep) { _, _ in proxy.scrollTo("top", anchor: .top) }
            }
            if !dynamicTypeSize.isAccessibilitySize { footer.padding(.horizontal, 24).padding(.bottom, 12) }
        }
        .background(MuesliTheme.backgroundBase).foregroundStyle(MuesliTheme.textPrimary)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showFileSharing) {
            if let url = shortcutURL { ActionButtonShortcutImportSheet(url: url) }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
        .onAppear {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--muesli-ui-testing-action-button-onboarding") { savedStep = 0; importOpened = false; settingsOpened = false }
            if args.contains("--muesli-ui-testing-action-button-assignment") { savedStep = 3 }
            if args.contains("--muesli-ui-testing-action-button-add") { savedStep = 2 }
            if args.contains("--muesli-ui-testing-action-button-returned") { savedStep = 3; settingsOpened = true }
            if args.contains("--muesli-ui-testing-action-button-meeting") { selectedMode = "meeting" }
            #endif
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .choose:
            heading("Action Button", mode == .dictation ? "Speak. Stop. Paste." : "Keep the conversation.", mode == .dictation ? "Turn a press into words you can paste into any app." : "Start and stop a meeting recording with your Action Button.")
            ForEach(ActionButtonCaptureMode.allCases, id: \.rawValue) { option in
                ActionButtonModeCard(mode: option, selected: mode == option) {
                    selectedMode = option.rawValue
                    importOpened = false
                    settingsOpened = false
                }
            }
            Text(mode == .dictation ? "Hold to start speaking. Hold again to stop. Muesli copies your words, ready to paste. No Muesli keyboard needed." : "Hold to start a meeting recording. Hold again to stop and save it in Muesli.")
                .foregroundStyle(MuesliTheme.textSecondary)
        case .prepare:
            heading("Before you begin", "Let Muesli listen.", "Your recording stays visible in the Dynamic Island and on your Lock Screen.")
            Label(microphoneReady ? "Microphone allowed" : "Microphone access needed", systemImage: microphoneReady ? "checkmark.circle" : "mic")
            Label(liveActivityReady ? "Live Activities enabled" : "Live Activities needed", systemImage: liveActivityReady ? "checkmark.circle" : "waveform")
            Label(coordinator.selectedTranscriptionModel.isDownloaded ? "On-device model ready" : "Download your model in Muesli first", systemImage: "arrow.down.circle")
            if mode == .dictation && !notificationsEnabled {
                Text("Allow notifications to see your words after they’re copied. You can also continue without them.")
                    .foregroundStyle(MuesliTheme.textSecondary)
                Button("Allow copied-text notifications") { Task {
                    let center = UNUserNotificationCenter.current()
                    let settings = await center.notificationSettings()
                    if settings.authorizationStatus == .denied { openSettings() }
                    else { _ = try? await center.requestAuthorization(options: [.alert]) }
                    await refresh()
                }}.frame(minHeight: 44).foregroundStyle(tint)
            }
        case .add:
            heading("Add to Shortcuts", "One small addition.\nReady every day.", "Apple’s Shortcuts app connects your Action Button to Muesli.")
            shortcutCard
            Text("Tap Add to Shortcuts below, then confirm Add Shortcut in Apple’s screen. If asked, replace the earlier version.")
                .foregroundStyle(MuesliTheme.textSecondary)
            Text("Then return here to assign your Action Button.").font(.headline)
            if importOpened {
                Text("Added it? Continue below. If you cancelled, tap Add to Shortcuts again.")
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            if shortcutURL == nil { Text("The shortcut file is missing from this build. Update Muesli to continue.").foregroundStyle(.orange) }
        case .assign:
            heading("Assign your Action Button", "Make the button\nyours.", "Choose this exact shortcut in iPhone Settings.")
            shortcutCard
            instruction(1, "Open Settings → Action Button", "The button below opens Muesli’s settings. Go back to the main Settings list, then select Action Button.")
            instruction(2, "Choose Shortcut", "Swipe to Shortcut, then tap Choose a Shortcut.")
            instruction(3, "Select \(shortcutName)", mode == .dictation ? "Look in your saved shortcuts, not inside the Muesli app-actions group." : "Look inside Muesli’s app-actions group.")
            Text("Return here when you’ve selected it. This replaces the button’s current assignment.")
                .foregroundStyle(MuesliTheme.textSecondary)
            if mode == .dictation {
                Button("Can’t find it? Add the shortcut again") { go(.add) }.frame(minHeight: 44).foregroundStyle(tint)
            }
        }
    }

    private var shortcutCard: some View {
        HStack(spacing: 16) {
            Image("MuesliAppIcon").resizable().scaledToFit().frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(shortcutName).font(.headline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(tint.opacity(0.3)) }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(primaryTitle) { primaryAction() }
                .font(.headline).foregroundStyle(Color(hex: 0x101721))
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(tint, in: RoundedRectangle(cornerRadius: 16))
                .disabled(openingImport || (step == .add && shortcutURL == nil))
                .accessibilityIdentifier(step == .assign ? "actionButton.openSettings" : "actionButton.primaryAction")
            if step == .add && importOpened {
                Button("Add to Shortcuts again") { openShortcutImport() }.frame(minHeight: 44).foregroundStyle(tint)
            }
            if step == .assign && settingsOpened {
                Button("Open Settings again") { openSettings() }.frame(minHeight: 44).foregroundStyle(tint)
            }
            if step != .choose {
                Button("Back") { go(step == .assign && mode == .meeting ? .prepare : step.previous) }
                    .frame(minHeight: 44).foregroundStyle(MuesliTheme.textSecondary)
            }
        }.buttonStyle(.plain)
    }

    private var primaryTitle: String {
        switch step {
        case .choose: return mode == .dictation ? "Set up Action Button dictation" : "Set up meeting recording"
        case .prepare:
            if !microphoneReady { return microphoneStatus == .notDetermined ? "Allow microphone" : "Open microphone settings" }
            if !liveActivityReady { return "Enable Live Activities" }
            if !coordinator.selectedTranscriptionModel.isDownloaded { return "Choose a downloaded model" }
            return "Continue"
        case .add: return openingImport ? "Opening Shortcuts…" : (importOpened ? "I added it — Continue" : "Add to Shortcuts")
        case .assign: return settingsOpened ? "I’ve assigned it — Done" : "Open Settings"
        }
    }

    private func primaryAction() {
        switch step {
        case .choose:
            if mode == .dictation { delivery = "clipboard" }
            go(.prepare)
        case .prepare:
            if !microphoneReady {
                if microphoneStatus == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in await refresh() } }
                } else { openSettings() }
            } else if !liveActivityReady {
                if mode == .dictation { dictationActivities = true } else { meetingActivities = true }
                if !ActivityAuthorizationInfo().areActivitiesEnabled { openSettings() }
            } else if !coordinator.selectedTranscriptionModel.isDownloaded { dismiss() }
            else { go(mode == .dictation ? .add : .assign) }
        case .add:
            if importOpened { go(.assign) } else { openShortcutImport() }
        case .assign:
            if settingsOpened {
                // Acknowledgement only; no recording-verification receipt is written.
                setupCompleted = true
                dismiss()
            } else { settingsOpened = true; openSettings() }
        }
    }

    private func openShortcutImport() {
        guard let url = shortcutURL else { return }
        openingImport = true
        importOpened = true
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in openingImport = false; showFileSharing = !opened }
        }
    }

    private func go(_ next: ActionButtonSetupStep) { savedStep = next.rawValue }
    private func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
    private func refresh() async {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsEnabled = settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
    }
    private func heading(_ eyebrow: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased()).font(.caption.weight(.semibold)).tracking(1.8).foregroundStyle(tint)
            Text(title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            Text(detail).foregroundStyle(MuesliTheme.textSecondary)
        }
    }
    private func instruction(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)").font(.headline).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(MuesliTheme.textSecondary)
            }
        }
    }
}

private enum ActionButtonSetupStep: Int { case choose, prepare, add, assign
    var previous: Self { Self(rawValue: max(0, rawValue - 1)) ?? .choose }
}

private struct ActionButtonModeCard: View {
    let mode: ActionButtonCaptureMode
    let selected: Bool
    let action: () -> Void
    private var tint: Color { mode == .dictation ? MuesliTheme.accent : MuesliTheme.syncGreen }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: mode == .dictation ? "waveform" : "person.2.wave.2")
                    .font(.system(size: 23, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 44, height: 44).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(mode == .dictation ? "Dictate text" : "Record a meeting").font(.headline)
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(mode == .dictation ? "A thought, straight into words." : "A conversation, kept together.")
                        .font(.subheadline).foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? tint : MuesliTheme.textSecondary)
                    .padding(.top, 2)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? tint.opacity(0.08) : MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? tint.opacity(0.65) : MuesliTheme.surfaceBorder, lineWidth: selected ? 1.5 : 1) }
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("actionButton.mode.\(mode.rawValue)")
    }
}

private struct ActionButtonOutputPreview: View {
    let mode: ActionButtonCaptureMode
    private var tint: Color { mode == .dictation ? MuesliTheme.accent : MuesliTheme.syncGreen }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("A GLIMPSE OF THE RESULT").font(.system(.caption2, weight: .semibold)).tracking(1.2)
                Spacer()
                Text("Preview").font(.caption)
            }.foregroundStyle(MuesliTheme.textSecondary)
            Rectangle().fill(tint).frame(width: 32, height: 3).accessibilityHidden(true)
            Text(mode == .dictation ? "Let's make space for a good idea." : "Monday's next big idea")
                .font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Label(mode == .dictation ? "Ready for your keyboard or clipboard" : "Recording, transcript, and notes in Meetings",
                  systemImage: mode == .dictation ? "text.cursor" : "note.text")
                .font(.footnote).foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct ActionButtonShortcutImportSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
