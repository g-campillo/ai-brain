import Foundation
import Testing
@testable import BrainKit

@Suite struct ChunkerTests {
    @Test func shortNoteIsOneChunk() {
        let chunks = Chunker.chunks(title: "VPN restart", body: "sudo launchctl kickstart vpn")
        #expect(chunks.count == 1)
        #expect(chunks[0].contains("VPN restart"))
    }

    @Test func longBodySplitsByHeadingWithTitlePrefixAndCap() {
        let section = String(repeating: "word ", count: 250) // ~1250 chars
        let body = "## Setup\n\(section)\n## Teardown\n\(section)"
        let chunks = Chunker.chunks(title: "Runbook", body: body, maxChars: 1500)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.hasPrefix("Runbook") })
        #expect(chunks.allSatisfy { $0.count <= 1500 })
    }
}

@Suite struct SearchTests {
    private func seededDB(embedder: Embedder) throws -> BrainDatabase {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try BrainDatabase.open(atPath: dir.appendingPathComponent("brain.db").path)

        var notes = [
            Note(type: .troubleshooting, title: "Publish times out during deployment",
                 body: "Site publish froze at 90 percent. Root cause: stale lock row in the scheduler table. Fix: clear the lock row and restart the publish job.",
                 project: "etk-sandbox", site: "county-a", tags: ["publish"]),
            Note(type: .runbook, title: "Rotate TLS certificates",
                 body: "Steps to renew and install the reverse proxy certificate before expiry.",
                 tags: ["tls"]),
            Note(type: .glossary, title: "EAB",
                 body: "EAB stands for Enterprise Application Builder, the internal site framework.",
                 tags: []),
            Note(type: .troubleshooting, title: "Login loop after SSO change",
                 body: "Users bounced back to login page. Cookie domain mismatch after IdP migration.",
                 tags: ["sso"], status: .archived),
        ]
        for i in notes.indices {
            try db.save(&notes[i])
            try db.indexEmbeddings(for: notes[i], using: embedder)
        }
        return db
    }

    @Test func keywordTermRanksItsNoteFirst() async throws {
        let embedder = try await Embedder.ready()
        let db = try seededDB(embedder: embedder)
        let hits = try db.search("EAB acronym meaning", embedder: embedder)
        #expect(hits.first?.note.title == "EAB")
    }

    @Test func semanticQueryFindsDifferentlyWordedNote() async throws {
        let embedder = try await Embedder.ready()
        let db = try seededDB(embedder: embedder)
        // No shared keywords with the note title/body wording ("deploy hangs" vs "publish times out").
        let hits = try db.search("deploy hangs and never finishes", embedder: embedder)
        #expect(hits.first?.note.title == "Publish times out during deployment")
    }

    @Test func filtersRestrictByTypeAndArchivedIsInvisible() async throws {
        let embedder = try await Embedder.ready()
        let db = try seededDB(embedder: embedder)

        let runbooksOnly = try db.search("certificate", filters: .init(type: .runbook), embedder: embedder)
        #expect(runbooksOnly.allSatisfy { $0.note.type == .runbook })
        #expect(!runbooksOnly.isEmpty)

        // The archived SSO note must never surface.
        let sso = try db.search("login loop SSO cookie mismatch", embedder: embedder)
        #expect(!sso.contains { $0.note.title == "Login loop after SSO change" })
    }

    @Test func keywordOnlySearchWorksWithoutEmbedder() async throws {
        let embedder = try await Embedder.ready()
        let db = try seededDB(embedder: embedder)
        let hits = try db.search("scheduler lock publish", embedder: nil)
        #expect(hits.first?.note.title == "Publish times out during deployment")
    }
}
