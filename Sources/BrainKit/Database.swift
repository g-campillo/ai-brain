import Foundation
import GRDB

/// Single source of truth: an embedded SQLite database (WAL) shared by the app,
/// the MCP server, and hook CLI processes.
public struct BrainDatabase: Sendable {
    public let pool: DatabasePool

    public static let defaultPath = FileManager.default
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

    private static var migrator: DatabaseMigrator {
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
