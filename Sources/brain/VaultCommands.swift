import ArgumentParser
import BrainKit
import Foundation

struct MigrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "One-time: back up the SQLite brain and dump it into the Obsidian vault (new source of truth)."
    )

    @Option(help: "Vault directory (defaults to $BRAIN_VAULT or ~/BrainVault).")
    var vault: String?

    func run() async throws {
        let db = try BrainDatabase.open()
        let backup = try db.backup()
        let dir = resolveVault(vault)
        let count = try db.exportToVault(dir)
        print("backed up db  -> \(backup)")
        print("migrated \(count) note(s) -> \(dir.path)")
        print("next: `brain reindex`, then open \(dir.path) as an Obsidian vault")
    }
}

struct ReindexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reindex",
        abstract: "Rebuild the search index from the vault. Safe to run anytime."
    )

    @Option(help: "Vault directory (defaults to $BRAIN_VAULT or ~/BrainVault).")
    var vault: String?

    @Flag(help: "Keyword index only — skip loading the embedding model.")
    var keywordOnly = false

    func run() async throws {
        let db = try BrainDatabase.open()
        let embedder = keywordOnly ? nil : try await Embedder.ready()
        let dir = resolveVault(vault)
        let stats = try db.reindex(vault: dir, embedder: embedder)
        print("reindexed \(dir.path): \(stats)")
    }
}

private func resolveVault(_ arg: String?) -> URL {
    guard let arg, !arg.isEmpty else { return Vault.defaultURL }
    return URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
}
