import BrainKit
import SwiftUI

struct MenuBarView: View {
    @Environment(BrainStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search the brain…", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }

            if !hits.isEmpty {
                ForEach(hits, id: \.note.id) { hit in
                    Button {
                        if let id = hit.note.id { store.selection = [id] }
                        store.sidebar = .all
                        store.refresh()
                        openWindow(id: "main")
                        NSApp.activate()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(hit.note.title).lineLimit(1)
                            Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
            }

            HStack {
                Button("Open Brain") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                if store.inboxCount > 0 {
                    Button("Inbox (\(store.inboxCount))") {
                        store.sidebar = .inbox
                        store.refresh()
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { store.refresh() }
    }

    private func runSearch() {
        Task {
            hits = Array((await store.playgroundSearch(query))?.hits.prefix(5) ?? [])
        }
    }
}
