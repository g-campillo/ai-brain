import BrainKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(BrainStore.self) private var store
    @State private var reindexStatus = ""
    @State private var reindexing = false
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
            Section("Database") {
                LabeledContent("Path") {
                    Text(BrainDatabase.defaultPath)
                        .textSelection(.enabled)
                        .font(.caption)
                }
                let counts = store.counts()
                LabeledContent("Notes", value: "\(counts.active) active · \(counts.archived) archived")
            }

            Section("Search") {
                LabeledContent("Embedding model") {
                    Text(store.embedder.map { "\($0.modelVersion) · \($0.dimension)d" } ?? "loading…")
                        .font(.caption)
                }
                HStack {
                    Button(reindexing ? "Reindexing…" : "Reindex missing/stale") {
                        reindexing = true
                        Task {
                            reindexStatus = await store.reindex(force: false)
                            reindexing = false
                        }
                    }
                    .disabled(reindexing)
                    Text(reindexStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Claude Code wiring") {
                Text("Hooks and the MCP server are managed by the CLI. From the repo: `make install` (idempotent, safe to re-run). Log: ~/Library/Logs/brain.log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
