import BrainKit
import SwiftUI

@main
struct BrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar-only app: the ⌥Space Ask panel (an AppKit NSPanel driven by
        // AskPanelController) is the surface; notes live in the Obsidian vault, so
        // there's no in-app note browser anymore.
        MenuBarExtra("Brain", systemImage: "brain") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
