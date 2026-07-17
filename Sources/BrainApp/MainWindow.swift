import BrainKit
import SwiftUI

struct MainWindow: View {
    @Environment(BrainStore.self) private var store
    @State private var sortOrder: [KeyPathComparator<Note>] = [.init(\.updatedAt, order: .reverse)]

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.sidebar) {
                Section("Browse") {
                    Label("All Notes", systemImage: "tray.full").tag(SidebarItem.all)
                    Label {
                        Text("Inbox")
                    } icon: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    .badge(store.inboxCount)
                    .tag(SidebarItem.inbox)
                    Label("Search Playground", systemImage: "scope").tag(SidebarItem.playground)
                }
                Section("Types") {
                    ForEach(NoteType.allCases, id: \.self) { type in
                        Label(type.rawValue, systemImage: "doc.text").tag(SidebarItem.type(type))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        } detail: {
            if store.sidebar == .playground {
                ContentUnavailableView("Playground runs in the middle column", systemImage: "scope")
            } else if let note = store.selectedNote() {
                NoteDetailView(note: note)
            } else {
                ContentUnavailableView("Select a note", systemImage: "brain")
            }
        }
        .onChange(of: store.sidebar) { store.refresh() }
        .toolbar {
            Button("New Note", systemImage: "square.and.pencil") { _ = store.newNote() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .alert("Brain error", isPresented: .constant(store.errorMessage != nil)) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        @Bindable var store = store
        switch store.sidebar {
        case .playground:
            PlaygroundView()
        case .inbox:
            InboxView()
        default:
            Table(store.notes, selection: $store.selection, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title)
                TableColumn("Type", value: \.type.rawValue) { note in
                    Text(note.type.rawValue)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Project") { note in Text(note.project ?? "—") }
                    .width(min: 70, ideal: 100)
                TableColumn("Site") { note in Text(note.site ?? "—") }
                    .width(min: 60, ideal: 80)
                TableColumn("Updated", value: \.updatedAt) { note in
                    Text(note.updatedAt, format: .dateTime.month().day().hour().minute())
                }
                .width(min: 100, ideal: 120)
            }
            .onChange(of: sortOrder) { _, newOrder in
                store.notes.sort(using: newOrder)
            }
        }
    }
}
