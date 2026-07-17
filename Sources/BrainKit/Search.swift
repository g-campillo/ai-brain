import Accelerate
import Foundation
import GRDB

public struct SearchFilters: Sendable {
    public var type: NoteType?
    public var project: String?
    public var site: String?
    public var tag: String?

    public init(type: NoteType? = nil, project: String? = nil, site: String? = nil, tag: String? = nil) {
        self.type = type
        self.project = project
        self.site = site
        self.tag = tag
    }
}

public struct SearchHit: Sendable {
    public let note: Note
    public let score: Double
    public let snippet: String
}

extension BrainDatabase {
    /// (Re)embeds a note's chunks. Call after every save that changes title/body.
    public func indexEmbeddings(for note: Note, using embedder: Embedder) throws {
        guard let id = note.id else { return }
        let vectors = try Chunker.chunks(title: note.title, body: note.body).map(embedder.embed)
        try saveEmbeddings(noteID: id, vectors: vectors, modelVersion: embedder.modelVersion)
    }

    /// Hybrid retrieval: FTS5 BM25 + cosine over chunk embeddings, fused with
    /// weighted RRF. The vector leg gets 2x weight — semantic match is the
    /// product's stated priority; keyword is the precision assist.
    public func search(
        _ query: String,
        k: Int = 5,
        filters: SearchFilters = SearchFilters(),
        embedder: Embedder?
    ) throws -> [SearchHit] {
        var conditions = ["n.status = 'active'"]
        var args: [DatabaseValueConvertible?] = []
        if let type = filters.type { conditions.append("n.type = ?"); args.append(type.rawValue) }
        if let project = filters.project { conditions.append("n.project = ?"); args.append(project) }
        if let site = filters.site { conditions.append("n.site = ?"); args.append(site) }
        if let tag = filters.tag { conditions.append("n.tags LIKE ?"); args.append("%\"\(tag)\"%") }
        let whereSQL = conditions.joined(separator: " AND ")

        // Keyword leg: AND-match for precision, OR-match fallback for recall.
        var keywordRanked: [Int64] = []
        var snippets: [Int64: String] = [:]
        let patterns = [
            FTS5Pattern(matchingAllTokensIn: query),
            FTS5Pattern(matchingAnyTokenIn: query),
        ].compactMap(\.self)
        for pattern in patterns where keywordRanked.isEmpty {
            let rows = try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT n.id AS id, snippet(note_fts, 1, '', '', ' … ', 24) AS snip
                    FROM note_fts
                    JOIN note n ON n.id = note_fts.rowid
                    WHERE note_fts MATCH ? AND \(whereSQL)
                    ORDER BY rank
                    LIMIT 50
                    """, arguments: StatementArguments([pattern as DatabaseValueConvertible?] + args))
            }
            keywordRanked = rows.map { $0["id"] }
            for row in rows { snippets[row["id"]] = row["snip"] }
        }

        // Vector leg: brute-force cosine (vectors are L2-normalized, so dot == cosine).
        // ponytail: full scan per query; add ANN + in-memory cache if notes exceed ~100k.
        var vectorRanked: [Int64] = []
        if let embedder {
            let queryVector = try embedder.embed(query)
            let rows = try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT e.noteId AS id, e.vector AS v
                    FROM embedding e JOIN note n ON n.id = e.noteId
                    WHERE \(whereSQL)
                    """, arguments: StatementArguments(args))
            }
            var bestPerNote: [Int64: Float] = [:]
            for row in rows {
                let vector = [Float](data: row["v"])
                guard vector.count == queryVector.count else { continue }
                var dot: Float = 0
                vDSP_dotpr(vector, 1, queryVector, 1, &dot, vDSP_Length(vector.count))
                let id: Int64 = row["id"]
                bestPerNote[id] = max(bestPerNote[id] ?? -.infinity, dot)
            }
            vectorRanked = bestPerNote
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(50)
                .map(\.key)
        }

        // Weighted reciprocal rank fusion, deterministic tiebreak on id.
        var fused: [Int64: Double] = [:]
        for (rank, id) in keywordRanked.enumerated() { fused[id, default: 0] += 1.0 / Double(61 + rank) }
        for (rank, id) in vectorRanked.enumerated() { fused[id, default: 0] += 2.0 / Double(61 + rank) }
        let topIDs = fused
            .sorted { ($0.value, Double($1.key)) > ($1.value, Double($0.key)) }
            .prefix(k)
            .map(\.key)
        guard !topIDs.isEmpty else { return [] }

        let notes = try pool.read { db in try Note.fetchAll(db, keys: topIDs) }
        let byID = Dictionary(uniqueKeysWithValues: notes.compactMap { note in note.id.map { ($0, note) } })
        return topIDs.compactMap { id in
            guard let note = byID[id] else { return nil }
            return SearchHit(note: note, score: fused[id] ?? 0, snippet: snippets[id] ?? String(note.body.prefix(200)))
        }
    }
}
