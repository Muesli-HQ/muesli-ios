import SwiftUI

struct RootView: View {
    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        TabView {
            DictationView(coordinator: coordinator)
                .tabItem {
                    Label("Dictate", systemImage: "mic.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}

