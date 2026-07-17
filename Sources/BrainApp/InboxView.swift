import BrainKit
import SwiftUI

/// Harvested candidates awaiting review: promote, open, or discard.
struct InboxView: View {
    @Environment(BrainStore.self) private var store

    var body: some View {
        @Bindable var store = store
        if store.inboxNotes.isEmpty {
            ContentUnavailableView(
                "Inbox empty",
                systemImage: "tray",
                description: Text("Session harvests land here for review before they become searchable.")
            )
        } else {
            List(store.inboxNotes, selection: $store.selection) { note in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(note.title).font(.headline)
                        Spacer()
                        Text(note.type.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(note.body)
                        .lineLimit(3)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        if let project = note.project {
                            Text(project).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Discard", role: .destructive) { store.discard(note) }
                        Button("Promote") { store.promote(note) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 6)
                .tag(note.id)
            }
        }
    }
}
