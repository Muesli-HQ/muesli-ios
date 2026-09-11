import SwiftUI

@main
struct MuesliApp: App {
    @UIApplicationDelegateAdaptor(MuesliAppDelegate.self) private var appDelegate
    @State private var coordinator: DictationCoordinator
    @Environment(\.scenePhase) private var scenePhase

    private var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.uiTestingLaunchArgument)
        #else
        false
        #endif
    }

    init() {
        _coordinator = State(initialValue: DictationCoordinator())
        AppTelemetry.configure()
    }

    var body: some Scene {
        WindowGroup {
            LaunchWarmupContainer(coordinator: coordinator) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--muesli-ui-testing-keyboard-permissions") {
                    OnboardingView(coordinator: coordinator)
                } else {
                    RootView(coordinator: coordinator)
                }
                #else
                RootView(coordinator: coordinator)
                #endif
            }
                .task {
                    #if DEBUG && targetEnvironment(simulator)
                    coordinator.startLiveActivityWaveformPreviewIfRequested()
                    #endif
                }
                #if DEBUG && targetEnvironment(simulator)
                .overlay(alignment: .top) {
                    if ProcessInfo.processInfo.arguments.contains("--muesli-ui-testing-island-waveform"), coordinator.isRecording {
                        Text("Waveform preview ready").accessibilityIdentifier("islandPreview.ready")
                    } else if let failure = coordinator.waveformPreviewFailure {
                        Text(failure).accessibilityIdentifier("islandPreview.failure")
                    }
                }
                #endif
                .alert("Copied to clipboard", isPresented: $coordinator.showsDictationCopyConfirmation) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Return to your app and paste. Select the Muesli keyboard to insert future dictations automatically.")
                }
                .onOpenURL { url in
                    coordinator.handleOpenURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        coordinator.copyPendingDictationIfActive()
                        #if DEBUG && targetEnvironment(simulator)
                        coordinator.startLiveActivityWaveformPreviewIfRequested()
                        #endif
                    }
                    if phase == .active, !isUITesting {
                        coordinator.reconcileMeetingRuntime(reason: "foreground")
                        coordinator.prewarmModelIfNeeded(reason: "foreground")
                        coordinator.syncICloudTextIfEnabled(reason: "foreground")
                        coordinator.recoverLongVoiceNotesIfNeeded()
                    }
                }
        }
    }
}
