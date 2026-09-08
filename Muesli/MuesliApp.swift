import SwiftUI

@main
struct MuesliApp: App {
    @UIApplicationDelegateAdaptor(MuesliAppDelegate.self) private var appDelegate
    @State private var coordinator = DictationCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    private var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.uiTestingLaunchArgument)
        #else
        false
        #endif
    }

    init() {
        AppTelemetry.configure()
    }

    var body: some Scene {
        WindowGroup {
            LaunchWarmupContainer(coordinator: coordinator) {
                RootView(coordinator: coordinator)
            }
                .task {
                    #if DEBUG && targetEnvironment(simulator)
                    await coordinator.previewLiveActivityWaveformIfRequested()
                    #endif
                }
                .alert("Copied to clipboard", isPresented: $coordinator.showsDictationCopyConfirmation) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Return to your app and paste. Select the Muesli keyboard to insert future dictations automatically.")
                }
                .onOpenURL { url in
                    coordinator.handleOpenURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { coordinator.copyPendingDictationIfActive() }
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
