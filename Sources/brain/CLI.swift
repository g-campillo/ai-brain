import ArgumentParser
import BrainKit
import Foundation

@main
struct Brain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brain",
        abstract: "Persistent knowledge base for Claude — MCP server, hooks, and admin tools.",
        subcommands: [MCPCommand.self, SearchCommand.self, BriefCommand.self, IndexCommand.self]
    )
}

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Query the brain (debug and hook entry point)."
    )

    @Option(name: .shortAndLong, help: "Query text.") var query: String
    @Option(name: .shortAndLong, help: "Max hits.") var k: Int = 5
    @Flag(help: "Keyword-only (skip the embedding model).") var keywordOnly = false

    func run() async throws {
        let db = try BrainDatabase.open()
        let embedder = keywordOnly ? nil : try await Embedder.ready()
        let result = try db.search(query, k: k, embedder: embedder)
        if result.hits.isEmpty { print("no hits") }
        for hit in result.hits {
            let sim = hit.vectorSimilarity.map { String(format: "%.3f", $0) } ?? "-"
            print("[\(hit.note.id ?? 0) · \(hit.note.type.rawValue) · rrf \(String(format: "%.4f", hit.score)) · sim \(sim)\(hit.matchedAllKeywords ? " · kw" : "")] \(hit.note.title)")
            print("  \(hit.snippet.replacingOccurrences(of: "\n", with: " "))")
        }
    }
}

struct BriefCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brief",
        abstract: "Print the project brief for a directory (SessionStart hook)."
    )

    @Option(help: "Working directory to brief.") var cwd: String

    func run() async throws {
        let db = try BrainDatabase.open()
        if let brief = try db.brief(forProjectPath: cwd) {
            print(brief)
        }
    }
}

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Embed notes whose vectors are missing or from an older model."
    )

    @Flag(help: "Re-embed every note regardless of stored model version.") var rebuild = false

    func run() async throws {
        let db = try BrainDatabase.open()
        let embedder = try await Embedder.ready()
        if rebuild { try db.deleteAllEmbeddings() }
        let notes = try db.notesNeedingEmbedding(modelVersion: embedder.modelVersion)
        for note in notes {
            try db.indexEmbeddings(for: note, using: embedder)
        }
        print("embedded \(notes.count) note(s) with \(embedder.modelVersion)")
    }
}
