import Foundation
import Testing
@testable import BrainKit

/// Worst-case retrieval budget: 10k notes, hybrid search, p95 < 100ms.
/// Bulk notes get deterministic synthetic vectors (bytes are bytes to the scan);
/// needle notes and every query use the real embedder, so the measured path is
/// the production path: embed query → FTS5 → cosine scan → RRF → fetch.
@Suite struct BenchmarkTests {
    @Test func tenThousandNoteP95Under100ms() async throws {
        let readyClock = ContinuousClock()
        let readyStart = readyClock.now
        let embedder = try await Embedder.ready()
        let readyElapsed = readyClock.now - readyStart

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try BrainDatabase.open(atPath: dir.appendingPathComponent("brain.db").path)

        var rng = SplitMix64(seed: 0xB4A1)
        let dim = embedder.dimension
        let seedClock = ContinuousClock()
        let seedStart = seedClock.now

        // 10k synthetic notes in batched transactions. Rows are generated outside
        // the write closure (it is Sendable; the RNG can't be mutated inside).
        let types = NoteType.allCases
        for batch in 0..<10 {
            var rows: [(Note, Data)] = []
            for i in 0..<1000 {
                let n = batch * 1000 + i
                let note = Note(
                    type: types[n % types.count],
                    title: Vocab.sentence(&rng, words: 5),
                    body: Vocab.sentence(&rng, words: 60) + " code E\(1000 + n)",
                    project: "proj-\(n % 20)",
                    site: "site-\(n % 50)",
                    tags: [Vocab.word(&rng), Vocab.word(&rng)]
                )
                rows.append((note, Data(vector: Self.randomUnitVector(dim: dim, rng: &rng))))
            }
            let batchRows = rows
            try await db.pool.write { sql in
                for (note, vectorData) in batchRows {
                    var inserted = note
                    try inserted.insert(sql)
                    try sql.execute(
                        sql: "INSERT INTO embedding (noteId, chunkIdx, vector, modelVersion) VALUES (?, 0, ?, 'synthetic')",
                        arguments: [inserted.id!, vectorData]
                    )
                }
            }
        }

        // Needles: real embeddings, distinctive content.
        let needles = [
            ("Kerberos ticket expired breaks nightly sync", "The overnight data sync job fails with GSSAPI auth errors because the service account Kerberos ticket expired. Renew the keytab and restart the sync daemon."),
            ("Widget cache invalidation loop", "Dashboard widgets flicker and reload forever. The cache key includes a timestamp so every render misses. Pin the cache key to content hash."),
            ("S3 lifecycle rule deleted backups", "Nightly database backups vanished. A misconfigured S3 lifecycle rule expired objects after one day. Fix the rule and re-enable versioning."),
        ]
        for (title, body) in needles {
            var note = Note(type: .troubleshooting, title: title, body: body, tags: ["needle"])
            try db.save(&note)
            try db.indexEmbeddings(for: note, using: embedder)
        }
        let seedElapsed = seedClock.now - seedStart

        // 50 timed queries: 6 needle-shaped (differently worded), 44 vocab noise.
        var queries = [
            "authentication failure on the overnight synchronization job",
            "expired kerberos credentials cron",
            "dashboard widgets keep refreshing endlessly",
            "cache never hits because key changes every time",
            "database backups disappeared from object storage",
            "s3 expiration policy removed my files",
        ]
        for _ in 0..<44 { queries.append(Vocab.sentence(&rng, words: 4)) }

        var durations: [Duration] = []
        let clock = ContinuousClock()
        for query in queries {
            let start = clock.now
            _ = try db.search(query, k: 5, embedder: embedder)
            durations.append(clock.now - start)
        }

        let sorted = durations.sorted()
        let p50 = sorted[24], p95 = sorted[47], worst = sorted[49]
        print("=== bench: ready=\(readyElapsed) seed(10k)=\(seedElapsed) p50=\(p50) p95=\(p95) max=\(worst)")

        #expect(p95 < .milliseconds(100), "p95 \(p95) blew the 100ms budget")

        // Relevance at scale: each needle query must surface its needle in the top 3.
        let needleQueries = [
            ("expired kerberos credentials break the overnight job", "Kerberos ticket expired breaks nightly sync"),
            ("widgets reload forever cache key timestamp", "Widget cache invalidation loop"),
            ("backups deleted by s3 lifecycle expiration", "S3 lifecycle rule deleted backups"),
        ]
        for (query, expectedTitle) in needleQueries {
            let hits = try db.search(query, k: 5, embedder: embedder).hits
            #expect(
                hits.prefix(3).contains { $0.note.title == expectedTitle },
                "needle '\(expectedTitle)' missing from top-3 for '\(query)': got \(hits.map(\.note.title))"
            )
        }
    }

    private static func randomUnitVector(dim: Int, rng: inout SplitMix64) -> [Float] {
        var v = (0..<dim).map { _ in Float(rng.nextUniform()) * 2 - 1 }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        for i in v.indices { v[i] /= norm }
        return v
    }
}

/// Deterministic RNG so the benchmark corpus is identical run to run.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func int(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

enum Vocab {
    static let bank = [
        "server", "deploy", "timeout", "database", "certificate", "login", "cache", "queue",
        "publish", "restart", "config", "index", "proxy", "session", "token", "migration",
        "cluster", "worker", "schedule", "backup", "storage", "network", "firewall", "latency",
        "upload", "render", "template", "form", "workflow", "permission", "audit", "export",
    ]

    static func word(_ rng: inout SplitMix64) -> String {
        bank[rng.int(below: bank.count)]
    }

    static func sentence(_ rng: inout SplitMix64, words: Int) -> String {
        (0..<words).map { _ in word(&rng) }.joined(separator: " ")
    }
}
