import BrainKit
import Foundation
import FoundationModels
import Observation

enum SidebarItem: Hashable {
    case all
    case inbox
    case playground
    case type(NoteType)
}

@MainActor
@Observable
final class BrainStore {
    let db: BrainDatabase
    private(set) var embedder: Embedder?

    var sidebar: SidebarItem = .all
    var notes: [Note] = []
    var inboxNotes: [Note] = []
    var selection: Set<Note.ID> = []
    var errorMessage: String?

    var inboxCount: Int { inboxNotes.count }

    var foundationModelsStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            "Available — session harvesting is active."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is OFF. Enable it in System Settings > Apple Intelligence & Siri to activate session harvesting."
        case .unavailable(.modelNotReady):
            "Model assets downloading — harvesting will activate when ready."
        case .unavailable(let reason):
            "Unavailable (\(String(describing: reason)))."
        }
    }

    init() {
        do {
            db = try BrainDatabase.open()
        } catch {
            fatalError("Cannot open brain database: \(error)")
        }
        refresh()
        Task { [weak self] in
            self?.embedder = try? await Embedder.ready()
        }
    }

    /// Manual refresh model: called on app activation and after every mutation.
    /// ponytail: no cross-process observation; hook-written notes appear on next activation.
    func refresh() {
        do {
            inboxNotes = try db.pool.read { db in
                try Note.filter(sql: "status = 'inbox'").order(sql: "updatedAt DESC").fetchAll(db)
            }
            switch sidebar {
            case .all:
                notes = try db.recent(500)
            case .type(let type):
                notes = try db.recent(500, filters: SearchFilters(type: type))
            case .inbox:
                notes = inboxNotes
            case .playground:
                break
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func selectedNote() -> Note? {
        guard let id = selection.first ?? nil else { return nil }
        return (notes + inboxNotes).first { $0.id == id }
    }

    // MARK: - Mutations

    func save(_ note: inout Note) {
        do {
            try db.save(&note)
            if let embedder { try db.indexEmbeddings(for: note, using: embedder) }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func newNote() -> Note? {
        var draft = Note(type: .howItWorks, title: "Untitled", body: "")
        save(&draft)
        if let id = draft.id { selection = [id] }
        return draft
    }

    func promote(_ note: Note) {
        var updated = note
        updated.status = .active
        save(&updated)
    }

    func archive(_ note: Note) {
        var updated = note
        updated.status = .archived
        save(&updated)
    }

    func discard(_ note: Note) {
        do {
            if let id = note.id { try db.deleteNote(id: id) }
            selection.removeAll()
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Playground

    func playgroundSearch(_ query: String) async -> SearchResult? {
        guard !query.isEmpty else { return nil }
        do {
            return try db.search(query, k: 10, embedder: embedder)
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    // MARK: - Maintenance

    func reindex(force: Bool) async -> String {
        guard let embedder else { return "Embedding model not loaded yet." }
        do {
            if force { try db.deleteAllEmbeddings() }
            let stale = try db.notesNeedingEmbedding(modelVersion: embedder.modelVersion)
            for note in stale {
                try db.indexEmbeddings(for: note, using: embedder)
            }
            return "Embedded \(stale.count) note(s)."
        } catch {
            return "Reindex failed: \(error)"
        }
    }

    func counts() -> (active: Int, inbox: Int, archived: Int) {
        let rows = (try? db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS c FROM note GROUP BY status")
        }) ?? []
        var active = 0, inbox = 0, archived = 0
        for row in rows {
            switch row["status"] as String? {
            case "active": active = row["c"]
            case "inbox": inbox = row["c"]
            case "archived": archived = row["c"]
            default: break
            }
        }
        return (active, inbox, archived)
    }
}

import GRDB
