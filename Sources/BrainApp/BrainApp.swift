import BrainKit
import SwiftUI

@main
struct BrainApp: App {
    @State private var store = BrainStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Brain", id: "main") {
            MainWindow()
                .environment(store)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.refresh() }
                }
        }
        .defaultSize(width: 1050, height: 640)
        // Login/background launches land as a menu-bar icon only; open the window
        // from the brain icon (or by relaunching from Finder/Dock).
        .defaultLaunchBehavior(.suppressed)
        .commands {
            SidebarCommands()
        }

        MenuBarExtra("Brain", systemImage: "brain") {
            MenuBarView()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
