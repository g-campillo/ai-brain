import Foundation
import GRDB

/// Single source of truth: an embedded SQLite database (WAL) shared by the app,
/// the MCP server, and hook CLI processes.
public struct BrainDatabase: Sendable {
    public let pool: DatabasePool

    /// Overridable via BRAIN_DB for tests and side-by-side experiments.
    public static let defaultPath = ProcessInfo.processInfo.environment["BRAIN_DB"]
        ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brain/brain.db").path

    public static func open(atPath path: String = defaultPath) throws -> BrainDatabase {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(path: path, configuration: config)
        try migrator.migrate(pool)
        return BrainDatabase(pool: pool)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("project", .text)
                t.column("site", .text)
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("jiraKey", .text)
                t.column("source", .text).notNull()
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(indexOn: "note", columns: ["status"])
            try db.create(indexOn: "note", columns: ["project"])

            try db.create(virtualTable: "note_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.synchronize(withTable: "note")
                t.column("title")
                t.column("body")
                t.column("tags")
            }

            try db.create(table: "embedding") { t in
                t.column("noteId", .integer).notNull()
                    .references("note", onDelete: .cascade)
                t.column("chunkIdx", .integer).notNull()
                t.column("vector", .blob).notNull()
                t.column("modelVersion", .text).notNull()
                t.primaryKey(["noteId", "chunkIdx"])
            }
        }
        migrator.registerMigration("v2") { db in
            // Approval flow removed: unreviewed harvest candidates are noise, not knowledge.
            // FTS cleanup rides the note triggers; embeddings are deleted explicitly so the
            // migration doesn't depend on foreign_keys pragma state.
            try db.execute(sql: "DELETE FROM embedding WHERE noteId IN (SELECT id FROM note WHERE status = 'inbox')")
            try db.execute(sql: "DELETE FROM note WHERE status = 'inbox'")
        }
        migrator.registerMigration("v3") { db in
            try db.create(table: "recall_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
                t.column("sessionId", .text).notNull()
                t.column("cwd", .text)
                t.column("prompt", .text).notNull()
                t.column("vectorMean", .double).notNull()
                t.column("vectorStd", .double).notNull()
                t.column("vectorCount", .integer).notNull()
                t.column("hits", .text).notNull() // JSON [RecallEvent.Hit]
            }
        }
        return migrator
    }

    // MARK: - Notes

    /// Insert or update; touches `updatedAt`.
    public func save(_ note: inout Note) throws {
        note.updatedAt = Date()
        note = try pool.write { [note] db in
            var copy = note
            try copy.save(db)
            return copy
        }
    }

    public func note(id: Int64) throws -> Note? {
        try pool.read { db in try Note.fetchOne(db, key: id) }
    }

    public func deleteNote(id: Int64) throws {
        _ = try pool.write { db in try Note.deleteOne(db, key: id) }
    }

    /// Newest active notes first, optionally filtered.
    public func recent(_ n: Int = 10, filters: SearchFilters = SearchFilters()) throws -> [Note] {
        try pool.read { db in
            var request = Note
                .filter(Column("status") == NoteStatus.active.rawValue)
                .order(Column("updatedAt").desc, Column("id").desc)
                .limit(n)
            if let type = filters.type { request = request.filter(Column("type") == type.rawValue) }
            if let project = filters.project { request = request.filter(Column("project") == project) }
            if let site = filters.site { request = request.filter(Column("site") == site) }
            if let tag = filters.tag { request = request.filter(Column("tags").like("%\"\(tag)\"%")) }
            return try request.fetchAll(db)
        }
    }

    // MARK: - Embeddings

    /// Replaces all embedding chunks for a note.
    public func saveEmbeddings(noteID: Int64, vectors: [[Float]], modelVersion: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM embedding WHERE noteId = ?", arguments: [noteID])
            let statement = try db.makeStatement(sql: """
                INSERT INTO embedding (noteId, chunkIdx, vector, modelVersion) VALUES (?, ?, ?, ?)
                """)
            for (idx, vector) in vectors.enumerated() {
                try statement.execute(arguments: [noteID, idx, Data(vector: vector), modelVersion])
            }
        }
    }

    public func deleteAllEmbeddings() throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM embedding") }
    }

    /// Notes whose embeddings are absent or produced by a different model.
    public func notesNeedingEmbedding(modelVersion: String) throws -> [Note] {
        try pool.read { db in
            try Note.fetchAll(db, sql: """
                SELECT n.* FROM note n
                LEFT JOIN embedding e ON e.noteId = n.id AND e.modelVersion = ?
                WHERE e.noteId IS NULL
                """, arguments: [modelVersion])
        }
    }

    public func embeddings(noteID: Int64) throws -> [[Float]] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT vector FROM embedding WHERE noteId = ? ORDER BY chunkIdx",
                arguments: [noteID]
            )
            return rows.map { [Float](data: $0["vector"]) }
        }
    }
}

// MARK: - Vector <-> BLOB

extension Data {
    init(vector: [Float]) {
        self = vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension [Float] {
    init(data: Data) {
        self = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
