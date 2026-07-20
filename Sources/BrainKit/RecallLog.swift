import Foundation
import GRDB

/// One UserPromptSubmit recall decision: what the gate saw and what it did.
/// Answers "why did/didn't the brain inject that note?" for real sessions,
/// the way PlaygroundView answers it for simulated prompts.
public struct RecallEvent: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "recall_event"

    /// Per-candidate snapshot. Title is copied so the row stays readable after
    /// the note is edited or deleted. z is derivable: (sim - vectorMean) / vectorStd.
    public struct Hit: Codable, Sendable {
        public let noteId: Int64
        public let title: String
        public let rrf: Double
        public let sim: Float?
        public let matchedAllKeywords: Bool
        /// Passed the confidence gate.
        public let confident: Bool
        /// Actually emitted (confident && !injected == session-deduped).
        public let injected: Bool

        public init(noteId: Int64, title: String, rrf: Double, sim: Float?,
                    matchedAllKeywords: Bool, confident: Bool, injected: Bool) {
            self.noteId = noteId
            self.title = title
            self.rrf = rrf
            self.sim = sim
            self.matchedAllKeywords = matchedAllKeywords
            self.confident = confident
            self.injected = injected
        }
    }

    public var id: Int64?
    public var createdAt: Date
    public var sessionId: String
    public var cwd: String?
    public var prompt: String
    public var vectorMean: Float
    public var vectorStd: Float
    public var vectorCount: Int
    public var hits: [Hit]

    public init(id: Int64? = nil, createdAt: Date = Date(), sessionId: String, cwd: String?,
                prompt: String, vectorMean: Float, vectorStd: Float, vectorCount: Int, hits: [Hit]) {
        self.id = id
        self.createdAt = createdAt
        self.sessionId = sessionId
        self.cwd = cwd
        self.prompt = prompt
        self.vectorMean = vectorMean
        self.vectorStd = vectorStd
        self.vectorCount = vectorCount
        self.hits = hits
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension BrainDatabase {
    /// ponytail: keep the last 500 events, pruned on every insert; age-based or
    /// configurable retention only if that ever matters.
    public func logRecall(_ event: inout RecallEvent) throws {
        event = try pool.write { [event] db in
            var copy = event
            try copy.insert(db)
            try db.execute(sql: """
                DELETE FROM recall_event
                WHERE id NOT IN (SELECT id FROM recall_event ORDER BY id DESC LIMIT 500)
                """)
            return copy
        }
    }

    public func recentRecallEvents(_ n: Int = 200) throws -> [RecallEvent] {
        try pool.read { db in
            try RecallEvent.order(Column("id").desc).limit(n).fetchAll(db)
        }
    }
}
