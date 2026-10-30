import SwiftUI

@main
struct MuesliApp: App {
    @UIApplicationDelegateAdaptor(MuesliAppDelegate.self) private var appDelegate
    @State private var coordinator: DictationCoordinator
    @Environment(\.scenePhase) private var scenePhase

    private var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.uiTestingLaunchArgument)
            || (Bundle.main.bundleIdentifier == "com.phequals7.muesli.ios.dev"
                && ProcessInfo.processInfo.arguments.contains("--muesli-validate-models"))
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
                    #if DEBUG
                    await ModelDownloadDeviceValidation.runIfRequested()
                    #endif
                    #if DEBUG && targetEnvironment(simulator)
                    coordinator.startLiveActivityWaveformPreviewIfRequested()
                    #endif
                }
                #if DEBUG && targetEnvironment(simulator)
                .overlay(alignment: .top) {
                    if ProcessInfo.processInfo.arguments.contains("--muesli-ui-testing-island-waveform"), coordinator.isRecording {
                        Text("Waveform preview ready").accessibilityIdentifier("islandPreview.ready")
                    } else if coordinator.waveformPreviewCopyPublished {
                        Text("Preview copy state published")
                            .accessibilityIdentifier("islandPreview.copyPublished")
                    } else if coordinator.waveformPreviewIsProcessing {
                        Button("Finish preview transcription") {
                            coordinator.waveformPreviewFinishRequested = true
                        }
                        .accessibilityIdentifier("islandPreview.finish")
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
                    coordinator.recordCaptureLifecycle("scene.\(phase)")
                    if phase == .active {
                        coordinator.refreshAudioImports()
                        coordinator.refreshDownloadedModels()
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
