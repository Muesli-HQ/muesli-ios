import SwiftUI

@main
struct MuesliApp: App {
    @State private var coordinator = DictationCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppTelemetry.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
                .onOpenURL { url in
                    coordinator.handleOpenURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        coordinator.prewarmModelIfNeeded(reason: "foreground")
                        coordinator.syncICloudTextIfEnabled(reason: "foreground")
                    }
                }
        }
    }
}
