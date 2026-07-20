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
    /// Max cosine of the query against this note's chunks (nil if no embedding).
    public let vectorSimilarity: Float?
    /// True when the note matched the precise AND-keyword pattern.
    public let matchedAllKeywords: Bool
    /// Long (≥8 char) query tokens found in the note — identifiers, error names,
    /// hostnames. Strong relevance evidence even when the corpus is tiny.
    public let distinctiveTokenMatches: [String]
}

public struct SearchResult: Sendable {
    public let hits: [SearchHit]
    /// Distribution of query↔note cosines across the whole (filtered) corpus.
    /// NLContextualEmbedding is anisotropic — absolute cosines cluster high — so
    /// relevance gating must use the per-query distribution, not a fixed floor.
    public let vectorMean: Float
    public let vectorStd: Float
    public let vectorCount: Int

    /// Hits confident enough for unsolicited injection (hooks). Three evidence
    /// paths, any suffices:
    /// 1. Every query token matched (terse keyword queries).
    /// 2. Distinctive-token overlap: ≥2 long tokens, or one ≥12 chars
    ///    (identifiers/error names) — works even in a tiny corpus.
    /// 3. Similarity z-score ≥ `zThreshold` against this query's own corpus
    ///    distribution (needs ≥20 embedded notes). 1.5 is calibrated: true
    ///    rewords ≈2.0, best on-topic non-answer ≈1.1, irrelevant ≤0.7.
    public func highConfidenceHits(max maxHits: Int = 3, zThreshold: Float = 1.5) -> [SearchHit] {
        hits.prefix(maxHits).filter { hit in
            if hit.matchedAllKeywords { return true }
            if hit.distinctiveTokenMatches.count >= 2 { return true }
            if hit.distinctiveTokenMatches.contains(where: { $0.count >= 12 }) { return true }
            guard vectorCount >= 20, vectorStd > 1e-4, let sim = hit.vectorSimilarity else { return false }
            return (sim - vectorMean) / vectorStd >= zThreshold
        }
    }
}

extension BrainDatabase {
    /// Save + refresh embeddings. Chunks are title-prefixed, so any title or body
    /// change invalidates vectors; pass nil to skip reindexing.
    public func save(_ note: inout Note, reindexingWith embedder: Embedder?) throws {
        try save(&note)
        if let embedder { try indexEmbeddings(for: note, using: embedder) }
    }

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
    ) throws -> SearchResult {
        var conditions = ["n.status = 'active'"]
        var args: [DatabaseValueConvertible?] = []
        if let type = filters.type { conditions.append("n.type = ?"); args.append(type.rawValue) }
        if let project = filters.project { conditions.append("n.project = ?"); args.append(project) }
        if let site = filters.site { conditions.append("n.site = ?"); args.append(site) }
        if let tag = filters.tag { conditions.append("n.tags LIKE ?"); args.append("%\"\(tag)\"%") }
        let whereSQL = conditions.joined(separator: " AND ")

        // Keyword leg: AND-match for precision, OR-match fallback for recall.
        var keywordRanked: [Int64] = []
        var andMatched: Set<Int64> = []
        var snippets: [Int64: String] = [:]
        let andPattern = FTS5Pattern(matchingAllTokensIn: query)
        let orPattern = FTS5Pattern(matchingAnyTokenIn: query)
        for (pattern, isAnd) in [(andPattern, true), (orPattern, false)].compactMap({ p, a in p.map { ($0, a) } })
        where keywordRanked.isEmpty {
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
            if isAnd { andMatched = Set(keywordRanked) }
            for row in rows { snippets[row["id"]] = row["snip"] }
        }

        // Vector leg: brute-force cosine (vectors are L2-normalized, so dot == cosine).
        // ponytail: full scan per query; add ANN + in-memory cache if notes exceed ~100k.
        var vectorRanked: [Int64] = []
        var similarity: [Int64: Float] = [:]
        if let embedder {
            let queryVector = try embedder.embed(query)
            let rows = try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT e.noteId AS id, e.vector AS v
                    FROM embedding e JOIN note n ON n.id = e.noteId
                    WHERE \(whereSQL)
                    """, arguments: StatementArguments(args))
            }
            for row in rows {
                let vector = [Float](data: row["v"])
                guard vector.count == queryVector.count else { continue }
                var dot: Float = 0
                vDSP_dotpr(vector, 1, queryVector, 1, &dot, vDSP_Length(vector.count))
                let id: Int64 = row["id"]
                similarity[id] = Swift.max(similarity[id] ?? -.infinity, dot)
            }
            vectorRanked = similarity
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(50)
                .map(\.key)
        }
        let sims = Array(similarity.values)
        let mean = sims.isEmpty ? 0 : sims.reduce(0, +) / Float(sims.count)
        let std = sims.count < 2 ? 0 : (sims.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(sims.count - 1)).squareRoot()

        // Weighted reciprocal rank fusion, deterministic tiebreak on id.
        var fused: [Int64: Double] = [:]
        for (rank, id) in keywordRanked.enumerated() { fused[id, default: 0] += 1.0 / Double(61 + rank) }
        for (rank, id) in vectorRanked.enumerated() { fused[id, default: 0] += 2.0 / Double(61 + rank) }
        let topIDs = fused
            .sorted { ($0.value, Double($1.key)) > ($1.value, Double($0.key)) }
            .prefix(k)
            .map(\.key)

        let notes = topIDs.isEmpty ? [] : try pool.read { db in try Note.fetchAll(db, keys: topIDs) }
        let byID = Dictionary(uniqueKeysWithValues: notes.compactMap { note in note.id.map { ($0, note) } })

        // Long tokens (identifiers, error names, hostnames) from the query.
        let distinctiveTokens = Set(
            query.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count >= 8 }
                .map(String.init)
        )

        let hits: [SearchHit] = topIDs.compactMap { id in
            guard let note = byID[id] else { return nil }
            let noteText = "\(note.title) \(note.body) \(note.tags.joined(separator: " "))".lowercased()
            return SearchHit(
                note: note,
                score: fused[id] ?? 0,
                snippet: snippets[id] ?? String(note.body.prefix(200)),
                vectorSimilarity: similarity[id],
                matchedAllKeywords: andMatched.contains(id),
                distinctiveTokenMatches: distinctiveTokens.filter(noteText.contains).sorted()
            )
        }
        return SearchResult(hits: hits, vectorMean: mean, vectorStd: std, vectorCount: sims.count)
    }
}
