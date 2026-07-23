import AppKit
import BrainKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError = ""

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginItemError = ""
                        } catch {
                            loginItemError = "\(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if !loginItemError.isEmpty {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Vault") {
                LabeledContent("Location") {
                    Text(Vault.defaultURL.path)
                        .textSelection(.enabled)
                        .font(.caption)
                }
                Button("Open Vault Folder") { NSWorkspace.shared.open(Vault.defaultURL) }
            }

            Section("Claude Code wiring") {
                Text("The Obsidian vault is the source of truth; the SQLite index rebuilds from it (`brain reindex`). Hooks and the MCP server are managed by the CLI: `make install`. Log: ~/Library/Logs/brain.log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
