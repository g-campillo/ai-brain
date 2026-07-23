import Foundation
import Testing
@testable import BrainKit

struct VaultTests {
    private func tempVault() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func frontmatterRoundTrip() throws {
        let note = Note(
            id: 7,
            type: .howItWorks,
            title: "Weird: title, with #hash & \"quotes\"",
            body: "intro line\n\n## Section\nkey: value with a colon\n",
            project: "ai-brain",
            site: "prod",
            tags: ["swiftui", "nspanel"],
            jiraKey: "TKP-14453"
        )
        let parsed = try Vault.parse(contents: Vault.emit(note), fallbackTitle: "fallback").note
        #expect(parsed.id == 7)
        #expect(parsed.title == note.title)
        #expect(parsed.type == .howItWorks)
        #expect(parsed.project == "ai-brain")
        #expect(parsed.site == "prod")
        #expect(parsed.tags == ["swiftui", "nspanel"])
        #expect(parsed.jiraKey == "TKP-14453")
        #expect(parsed.body.contains("key: value with a colon"))
    }

    @Test func reconcileAddsUpdatesDeletes() throws {
        let dir = try tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try BrainDatabase.open(atPath: dir.appendingPathComponent("index.db").path)

        try Vault.write(Note(id: 1, type: .snippet, title: "One", body: "alpha"), to: dir)
        let add = try db.reconcile(vault: dir, embedder: nil)
        #expect(add.added == 1)
        #expect(try db.note(id: 1)?.body == "alpha")

        // Edit the same note (same id, new body) — must update, not duplicate.
        try Vault.write(Note(id: 1, type: .snippet, title: "One", body: "beta"), to: dir)
        let edit = try db.reconcile(vault: dir, embedder: nil)
        #expect(edit.updated == 1)
        #expect(try db.note(id: 1)?.body == "beta")

        // No change — should be a no-op.
        let noop = try db.reconcile(vault: dir, embedder: nil)
        #expect(noop.unchanged == 1)
        #expect(noop.updated == 0)

        // Delete the file — index row must be dropped.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(Vault.filename(id: 1, title: "One")))
        let del = try db.reconcile(vault: dir, embedder: nil)
        #expect(del.deleted == 1)
        #expect(try db.note(id: 1) == nil)
    }

    @Test func stampsIdOntoHandCreatedNote() throws {
        let dir = try tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try BrainDatabase.open(atPath: dir.appendingPathComponent("index.db").path)

        // A note authored in Obsidian: emitted with no `id:` frontmatter.
        let raw = Vault.emit(Note(type: .learning, title: "Hand written", body: "content"))
        try raw.write(to: dir.appendingPathComponent("hand written.md"), atomically: true, encoding: .utf8)

        let stats = try db.reconcile(vault: dir, embedder: nil)
        #expect(stats.stamped == 1)
        #expect(try db.note(id: 1)?.title == "Hand written")

        // The id was written back into the vault, so it's stable next run.
        let ids = try Vault.list(dir).compactMap { try Vault.read($0).note.id }
        #expect(ids == [1])
    }

    @Test func upsertAllocatesIdWritesFileAndRenames() throws {
        let dir = try tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try BrainDatabase.open(atPath: dir.appendingPathComponent("index.db").path)

        let first = try db.upsertToVault(Note(type: .snippet, title: "First", body: "x"), vault: dir, embedder: nil)
        #expect(first.id == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(Vault.filename(id: 1, title: "First")).path))
        #expect(try db.note(id: 1)?.body == "x")

        // A second save allocates the next id.
        let second = try db.upsertToVault(Note(type: .snippet, title: "Second", body: "y"), vault: dir, embedder: nil)
        #expect(second.id == 2)

        // A title change renames the file: old gone, same id, no duplicate.
        var edit = try #require(try db.note(id: 1))
        edit.title = "First Renamed"
        _ = try db.upsertToVault(edit, vault: dir, embedder: nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Vault.filename(id: 1, title: "First")).path))
        #expect(try db.note(id: 1)?.title == "First Renamed")
        let ids2 = try Vault.list(dir).compactMap { try Vault.read($0).note.id }.sorted()
        #expect(ids2 == [1, 2])
    }
}
