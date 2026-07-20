import BrainKit
import SwiftUI

struct NoteDetailView: View {
    @Environment(BrainStore.self) private var store
    let note: Note

    @State private var editing = false
    @State private var draft = Note(type: .howItWorks, title: "", body: "")

    var body: some View {
        Group {
            if editing {
                editor
            } else {
                reader
            }
        }
        .toolbar {
            Button(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil") {
                if editing {
                    var toSave = draft
                    store.save(&toSave)
                } else {
                    draft = note
                }
                editing.toggle()
            }
            .keyboardShortcut(editing ? .return : "e", modifiers: .command)
            Menu {
                Button("Archive") { store.archive(note) }
                Button("Delete", role: .destructive) { store.discard(note) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .onChange(of: note.id) { editing = false }
    }

    private var reader: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(note.title).font(.title2.bold())
                HStack(spacing: 10) {
                    badge(note.type.rawValue)
                    if let project = note.project { badge("project: \(project)") }
                    if let site = note.site { badge("site: \(site)") }
                    if let jira = note.jiraKey { badge(jira) }
                    if note.status != .active { badge(note.status.rawValue.uppercased()) }
                }
                if !note.tags.isEmpty {
                    Text(note.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text(rendered(note.body))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Text("\(note.source.rawValue) · created \(note.createdAt.formatted()) · updated \(note.updatedAt.formatted())")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
    }

    private var editor: some View {
        Form {
            TextField("Title", text: $draft.title)
            Picker("Type", selection: $draft.type) {
                ForEach(NoteType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            TextField("Project", text: optional($draft.project))
            TextField("Site", text: optional($draft.site))
            TextField("Jira key", text: optional($draft.jiraKey))
            TextField("Tags (comma separated)", text: Binding(
                get: { draft.tags.joined(separator: ", ") },
                set: { draft.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            TextEditor(text: $draft.body)
                .font(.body.monospaced())
                .frame(minHeight: 260)
        }
        .padding()
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
