import AppKit
import BrainKit
import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Ask Claude  ⌥Space") {
                AskPanelController.shared.show()
            }
            Divider()
            Button("Open Vault Folder") {
                NSWorkspace.shared.open(Vault.defaultURL)
            }
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
