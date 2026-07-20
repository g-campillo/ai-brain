import Foundation
import GRDB
import Testing
@testable import BrainKit

@Suite struct DatabaseTests {
    private func tempDB() throws -> BrainDatabase {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try BrainDatabase.open(atPath: dir.appendingPathComponent("brain.db").path)
    }

    @Test func noteRoundTripsAndFTSIndexFollows() throws {
        let db = try tempDB()

        var note = Note(
            type: .troubleshooting,
            title: "Publish hangs on ETK site",
            body: "Deploy queue stuck because the scheduler lock table had a stale row.",
            project: "etk-sandbox",
            site: "county-a",
            tags: ["deploy", "scheduler"]
        )
        try db.save(&note)
        let id = try #require(note.id)

        let fetched = try #require(try db.note(id: id))
        #expect(fetched.title == note.title)
        #expect(fetched.tags == ["deploy", "scheduler"])
        #expect(fetched.status == .active)

        // FTS index is trigger-synced: a body-only word must match immediately.
        // ("stuck" appears only in body — tags are indexed too, so the probe term
        // must not overlap them.)
        let matches = try db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_fts WHERE note_fts MATCH ?", arguments: ["stuck"])
        }
        #expect(matches == 1)

        // Updates propagate to the index.
        note.body = "Root cause was an expired certificate on the reverse proxy."
        try db.save(&note)
        let stale = try db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_fts WHERE note_fts MATCH ?", arguments: ["stuck"])
        }
        #expect(stale == 0)
        // Tag terms keep matching after the body change.
        let tagged = try db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_fts WHERE note_fts MATCH ?", arguments: ["scheduler"])
        }
        #expect(tagged == 1)
    }

    @Test func embeddingsRoundTripAndCascadeDelete() throws {
        let db = try tempDB()

        var note = Note(type: .snippet, title: "VPN restart", body: "sudo launchctl kickstart vpn", tags: [])
        try db.save(&note)
        let id = try #require(note.id)

        let vectors: [[Float]] = [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
        try db.saveEmbeddings(noteID: id, vectors: vectors, modelVersion: "test-v1")

        let stored = try db.embeddings(noteID: id)
        #expect(stored == vectors)

        // Replacing embeddings overwrites, not appends.
        try db.saveEmbeddings(noteID: id, vectors: [[9, 9, 9]], modelVersion: "test-v2")
        #expect(try db.embeddings(noteID: id) == [[9, 9, 9]])

        try db.deleteNote(id: id)
        #expect(try db.embeddings(noteID: id).isEmpty)
    }

    @Test func v2MigrationDropsInboxRowsAndTheirIndexData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("brain.db").path

        // Build a v1-era database containing a legacy inbox row with FTS + embedding data.
        let pool = try DatabasePool(path: path)
        try BrainDatabase.migrator.migrate(pool, upTo: "v1")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO note (type, title, body, tags, source, status, createdAt, updatedAt)
                VALUES ('learning', 'kept note', 'stays', '[]', 'manual', 'active', ?, ?),
                       ('learning', 'pending harvest', 'zebrafish body', '[]', 'harvest', 'inbox', ?, ?)
                """, arguments: [Date(), Date(), Date(), Date()])
            try db.execute(sql: "INSERT INTO embedding (noteId, chunkIdx, vector, modelVersion) VALUES (2, 0, x'00000000', 'test')")
        }
        let ftsBefore = try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_fts WHERE note_fts MATCH 'zebrafish'")
        }
        #expect(ftsBefore == 1)

        // Opening the database migrates to head; v2 deletes unreviewed inbox rows.
        let brain = try BrainDatabase.open(atPath: path)
        let titles = try brain.pool.read { db in try String.fetchAll(db, sql: "SELECT title FROM note") }
        #expect(titles == ["kept note"])
        let embeddings = try brain.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding")
        }
        #expect(embeddings == 0)
        let ftsAfter = try brain.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_fts WHERE note_fts MATCH 'zebrafish'")
        }
        #expect(ftsAfter == 0)
    }

    @Test func v3MigrationCreatesRecallEventTable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("brain.db").path

        // A v2-era database (pre recall log) migrates cleanly on open.
        let pool = try DatabasePool(path: path)
        try BrainDatabase.migrator.migrate(pool, upTo: "v2")

        let brain = try BrainDatabase.open(atPath: path)
        let table = try brain.pool.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'recall_event'")
        }
        #expect(table == "recall_event")
    }

    @Test func saveReindexingSkipsWhenNilAndReindexesOnChange() async throws {
        let db = try tempDB()

        var note = Note(type: .snippet, title: "original", body: "body text")
        try db.save(&note)
        let id = try #require(note.id)
        try db.saveEmbeddings(noteID: id, vectors: [[1, 2, 3]], modelVersion: "fake")

        // nil embedder: metadata-only update leaves vectors untouched.
        note.project = "ai-brain"
        try db.save(&note, reindexingWith: nil)
        #expect(try db.embeddings(noteID: id) == [[1, 2, 3]])

        // Real embedder: text change replaces the fake vectors.
        note.title = "renamed"
        let embedder = try await Embedder.ready()
        try db.save(&note, reindexingWith: embedder)
        let vectors = try db.embeddings(noteID: id)
        #expect(!vectors.isEmpty)
        #expect(vectors != [[1, 2, 3]])
    }

    @Test func notesNeedingEmbeddingFindsMissingAndStale() throws {
        let db = try tempDB()

        var fresh = Note(type: .snippet, title: "fresh", body: "a")
        var stale = Note(type: .snippet, title: "stale", body: "b")
        var missing = Note(type: .snippet, title: "missing", body: "c")
        try db.save(&fresh)
        try db.save(&stale)
        try db.save(&missing)
        try db.saveEmbeddings(noteID: fresh.id!, vectors: [[1]], modelVersion: "current")
        try db.saveEmbeddings(noteID: stale.id!, vectors: [[1]], modelVersion: "old")

        let needing = try db.notesNeedingEmbedding(modelVersion: "current")
        #expect(Set(needing.map(\.title)) == ["stale", "missing"])
    }
}
