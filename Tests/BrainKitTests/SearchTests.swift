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

    /// Broad corpus so the per-query similarity distribution is meaningful (n >= 20).
    private func paddedDB(embedder: Embedder) throws -> BrainDatabase {
        let db = try seededDB(embedder: embedder)
        let fillers = [
            "Nightly backup job schedule and retention policy",
            "How the load balancer health checks decide to evict a node",
            "Steps to onboard a new county site into the fleet",
            "Where the audit log files live and how long we keep them",
            "Firewall change request process for new integrations",
            "How session cookies are scoped across subdomains",
            "Maven build profiles used by the CI pipeline",
            "Where database connection strings are configured per env",
            "How the form template cache is warmed after deploys",
            "Escalation path for after-hours production incidents",
            "How to grant a developer read access to production logs",
            "Workflow engine retry semantics for failed steps",
            "Where uploaded documents are stored and virus scanned",
            "How the search reindex job is scheduled monthly",
            "Sandbox environment refresh procedure from prod snapshots",
            "How feature flags are toggled per site",
            "Email relay configuration and SPF records",
            "How report exports stream to avoid memory spikes",
            "Access token lifetimes for the integration API",
            "How the print service renders PDFs headlessly",
        ]
        for (i, title) in fillers.enumerated() {
            var note = Note(type: .howItWorks, title: title, body: title + ". Details recorded elsewhere.", tags: ["filler\(i)"])
            try db.save(&note)
            try db.indexEmbeddings(for: note, using: embedder)
        }
        return db
    }

    @Test func keywordTermRanksItsNoteFirst() async throws {
        let embedder = try await Embedder.ready()
        let db = try seededDB(embedder: embedder)
        let hits = try db.search("EAB acronym meaning", embedder: embedder).hits
        #expect(hits.first?.note.title == "EAB")
    }

    @Test func semanticQueryFindsDifferentlyWordedNote() async throws {
        let embedder = try await Embedder.ready()
        let db = try seededDB(embedder: embedder)
        // No shared keywords with the note title/body wording ("deploy hangs" vs "publish times out").
        let hits = try db.search("deploy hangs and never finishes", embedder: embedder).hits
        #expect(hits.first?.note.title == "Publish times out during deployment")
    }

    @Test func filtersRestrictByTypeAndArchivedIsInvisible() async throws {
        let embedder = try await Embedder.ready()
        let db = try seededDB(embedder: embedder)

        let runbooksOnly = try db.search("certificate", filters: .init(type: .runbook), embedder: embedder).hits
        #expect(runbooksOnly.allSatisfy { $0.note.type == .runbook })
        #expect(!runbooksOnly.isEmpty)

        // The archived SSO note must never surface.
        let sso = try db.search("login loop SSO cookie mismatch", embedder: embedder).hits
        #expect(!sso.contains { $0.note.title == "Login loop after SSO change" })
    }

    @Test func keywordOnlySearchWorksWithoutEmbedder() async throws {
        let embedder = try await Embedder.ready()
        let db = try seededDB(embedder: embedder)
        let hits = try db.search("scheduler lock publish", embedder: nil).hits
        #expect(hits.first?.note.title == "Publish times out during deployment")
    }

    // MARK: - Hook confidence gate

    @Test func irrelevantPromptYieldsNoConfidentHits() async throws {
        let embedder = try await Embedder.ready()
        let db = try paddedDB(embedder: embedder)
        let result = try db.search("best oven temperature for sourdough bread", embedder: embedder)
        #expect(result.highConfidenceHits().isEmpty)

        let smalltalk = try db.search("what should I eat for lunch", embedder: embedder)
        #expect(smalltalk.highConfidenceHits().isEmpty)
    }

    @Test func rewordedIssuePassesConfidenceGate() async throws {
        let embedder = try await Embedder.ready()
        let db = try paddedDB(embedder: embedder)
        let result = try db.search("my deploy hangs at ninety percent and never finishes", embedder: embedder)
        let confident = result.highConfidenceHits()
        #expect(confident.contains { $0.note.title == "Publish times out during deployment" })
    }

    @Test func exactKeywordMatchPassesGateEvenInTinyCorpus() async throws {
        let embedder = try await Embedder.ready()
        let db = try seededDB(embedder: embedder) // only 3 active notes
        let result = try db.search("scheduler lock row publish", embedder: embedder)
        let confident = result.highConfidenceHits()
        #expect(confident.contains { $0.note.title == "Publish times out during deployment" })
    }
}
