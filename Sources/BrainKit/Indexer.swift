import Foundation
import GRDB

public struct ReconcileStats: Sendable, CustomStringConvertible {
    public var added = 0
    public var updated = 0
    public var deleted = 0
    public var unchanged = 0
    public var stamped = 0
    public var conflicts = 0

    public var description: String {
        var parts = ["\(added) added", "\(updated) updated", "\(deleted) removed", "\(unchanged) unchanged"]
        if stamped > 0 { parts.append("\(stamped) stamped") }
        if conflicts > 0 { parts.append("\(conflicts) conflicts") }
        return parts.joined(separator: ", ")
    }
}

extension BrainDatabase {
    /// Rebuild the whole index from the vault. Safe anytime — the vault is truth,
    /// so the index is disposable.
    @discardableResult
    public func reindex(vault dir: URL = Vault.defaultURL, embedder: Embedder?) throws -> ReconcileStats {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM embedding")
            try db.execute(sql: "DELETE FROM note")
        }
        return try reconcile(vault: dir, embedder: embedder)
    }

    /// Bring the index in line with the vault: add new files, re-embed changed
    /// ones, drop deleted ones, and stamp ids onto notes hand-created in Obsidian.
    ///
    /// Identity is the frontmatter `id`, not the path — so renaming/moving a file
    /// in Obsidian is safe. A file that fails to parse is left as-is (its existing
    /// index row is kept, not deleted), so a mid-edit invalid save self-heals on
    /// the next run.
    ///
    /// ponytail: hashes every file each run (no mtime fast-path). Fine for a
    /// single-user vault of hundreds–low-thousands of notes; add a size/mtime
    /// prefilter if it ever grows past that.
    @discardableResult
    public func reconcile(vault dir: URL = Vault.defaultURL, embedder: Embedder?) throws -> ReconcileStats {
        var stats = ReconcileStats()

        struct Indexed { var id: Int64; var path: String?; var hash: String? }
        let indexed = try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path, contentHash FROM note").map {
                Indexed(id: $0["id"], path: $0["path"], hash: $0["contentHash"])
            }
        }
        var hashByID: [Int64: String] = [:]
        for row in indexed where row.hash != nil { hashByID[row.id] = row.hash }
        var nextID = (indexed.map(\.id).max() ?? 0) + 1
        var seen = Set<Int64>()

        for url in try Vault.list(dir) {
            guard var file = try? Vault.read(url) else {
                warn("skipped \(url.lastPathComponent): unreadable or invalid frontmatter")
                continue
            }

            // A note authored in Obsidian has no id: assign one and stamp it back
            // into the file so citations ([id N]) stay stable.
            if file.note.id == nil {
                var stamped = file.note
                stamped.id = nextID
                nextID += 1
                let newURL = try Vault.write(stamped, to: dir)
                if newURL.path != url.path { try? FileManager.default.removeItem(at: url) }
                file = try Vault.read(newURL)
                stats.stamped += 1
            }
            guard let id = file.note.id else { continue }
            guard !seen.contains(id) else {
                stats.conflicts += 1
                warn("duplicate id \(id) at \(url.lastPathComponent): skipped")
                continue
            }
            seen.insert(id)

            let existed = hashByID[id] != nil
            if existed, hashByID[id] == file.contentHash {
                // Unchanged content (possibly moved): refresh the recorded path only.
                try pool.write { db in
                    try db.execute(sql: "UPDATE note SET path = ? WHERE id = ?", arguments: [file.url.path, id])
                }
                stats.unchanged += 1
                continue
            }

            let note = file.note
            let path = file.url.path
            let hash = file.contentHash
            try pool.write { db in
                var row = note
                if existed { try row.update(db) } else { try row.insert(db) }
                try db.execute(
                    sql: "UPDATE note SET path = ?, contentHash = ? WHERE id = ?",
                    arguments: [path, hash, id]
                )
            }
            if let embedder { try indexEmbeddings(for: note, using: embedder) }
            if existed { stats.updated += 1 } else { stats.added += 1 }
        }

        // Delete index rows whose file is genuinely gone — not merely unparseable
        // this run (parse failures keep the stale row so a bad save doesn't drop a note).
        let removable = indexed.filter { row in
            guard !seen.contains(row.id) else { return false }
            // Only delete on positive evidence the file was removed: the row had a
            // recorded path and that path is now gone. A NULL-path row (e.g. written
            // by an out-of-date process that predates the vault columns) is kept, not
            // reaped — losing a note to a transient state is worse than a stale row,
            // which `reindex` clears anyway.
            guard let p = row.path else { return false }
            return !FileManager.default.fileExists(atPath: p)
        }
        if !removable.isEmpty {
            try pool.write { db in
                for row in removable { try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [row.id]) }
            }
            stats.deleted = removable.count
        }
        return stats
    }

    /// Migration: write every note (all statuses) into the vault as markdown.
    @discardableResult
    public func exportToVault(_ dir: URL = Vault.defaultURL) throws -> Int {
        let notes = try pool.read { db in try Note.order(Column("id")).fetchAll(db) }
        for note in notes { try Vault.write(note, to: dir) }
        return notes.count
    }

    /// Snapshot the SQLite file next to itself before the vault takes over.
    /// VACUUM INTO produces one clean file (no separate WAL/SHM to worry about).
    @discardableResult
    public func backup() throws -> String {
        let dest = path + ".pre-obsidian.bak"
        try? FileManager.default.removeItem(atPath: dest)
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [dest])
        }
        return dest
    }

    /// Write a note to the vault (the source of truth) and update the index to
    /// match: allocate an id for new notes, re-embed, and delete the old file if a
    /// title change renamed it. Returns the saved note (with id). This is the write
    /// path for `brain_save` / `brain_update`.
    ///
    /// ponytail: id allocation is MAX(id)+1 with no lock — fine for a single-user
    /// brain; add a sequence table if concurrent writers ever appear.
    @discardableResult
    public func upsertToVault(_ note: Note, vault dir: URL = Vault.defaultURL, embedder: Embedder?) throws -> Note {
        var note = note
        note.updatedAt = Date()
        let oldPath = try note.id.flatMap { id in
            try pool.read { db in try String.fetchOne(db, sql: "SELECT path FROM note WHERE id = ?", arguments: [id]) }
        }
        if note.id == nil {
            let maxID = try pool.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM note") } ?? 0
            note.id = maxID + 1
        }
        guard let id = note.id else { return note }
        let existed = try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE id = ?)", arguments: [id])
        } ?? false

        let url = try Vault.write(note, to: dir)
        if let oldPath, oldPath != url.path { try? FileManager.default.removeItem(atPath: oldPath) }
        let hash = try Vault.read(url).contentHash

        let saved = note
        try pool.write { db in
            var row = saved
            if existed { try row.update(db) } else { try row.insert(db) }
            try db.execute(sql: "UPDATE note SET path = ?, contentHash = ? WHERE id = ?", arguments: [url.path, hash, id])
        }
        if let embedder { try indexEmbeddings(for: saved, using: embedder) }
        return saved
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("brain reconcile: \(message)\n".utf8))
    }
}
