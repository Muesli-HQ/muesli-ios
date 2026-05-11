import SwiftUI

@main
struct MuesliApp: App {
    @State private var coordinator = DictationCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
                .onOpenURL { url in
                    coordinator.handleOpenURL(url)
                }
        }
    }
}

