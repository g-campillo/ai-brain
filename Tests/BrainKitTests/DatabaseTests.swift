import Foundation
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
}
