import BrainKit
import Foundation
import Observation

enum SidebarItem: Hashable {
    case all
    case playground
    case recall
    case type(NoteType)
}

@MainActor
@Observable
final class BrainStore {
    let db: BrainDatabase
    private(set) var embedder: Embedder?

    var sidebar: SidebarItem = .all
    var notes: [Note] = []
    var recallEvents: [RecallEvent] = []
    var selection: Set<Note.ID> = []
    var errorMessage: String?

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
            switch sidebar {
            case .all:
                notes = try db.recent(500)
            case .type(let type):
                notes = try db.recent(500, filters: SearchFilters(type: type))
            case .recall:
                recallEvents = try db.recentRecallEvents(200)
            case .playground:
                break
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func selectedNote() -> Note? {
        guard let id = selection.first ?? nil else { return nil }
        return notes.first { $0.id == id }
    }

    // MARK: - Mutations

    func save(_ note: inout Note) {
        do {
            try db.save(&note, reindexingWith: embedder)
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

    func counts() -> (active: Int, archived: Int) {
        let rows = (try? db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS c FROM note GROUP BY status")
        }) ?? []
        var active = 0, archived = 0
        for row in rows {
            switch row["status"] as String? {
            case "active": active = row["c"]
            case "archived": archived = row["c"]
            default: break
            }
        }
        return (active, archived)
    }
}

import GRDB
