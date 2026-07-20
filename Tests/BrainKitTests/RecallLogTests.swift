import Foundation
import GRDB
import Testing
@testable import BrainKit

@Suite struct RecallLogTests {
    private func tempDB() throws -> BrainDatabase {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try BrainDatabase.open(atPath: dir.appendingPathComponent("brain.db").path)
    }

    @Test func eventRoundTripsWithHitsJSONNewestFirst() throws {
        let db = try tempDB()

        var event = RecallEvent(
            sessionId: "s1", cwd: "/tmp/proj", prompt: "why does publish hang",
            vectorMean: 0.5, vectorStd: 0.1, vectorCount: 30,
            hits: [
                .init(noteId: 1, title: "Publish hangs", rrf: 0.04, sim: 0.72,
                      matchedAllKeywords: true, confident: true, injected: true),
                .init(noteId: 2, title: "TLS rotate", rrf: 0.01, sim: 0.51,
                      matchedAllKeywords: false, confident: false, injected: false),
            ]
        )
        try db.logRecall(&event)
        #expect(event.id != nil)

        var second = RecallEvent(
            sessionId: "s1", cwd: nil, prompt: "later prompt",
            vectorMean: 0, vectorStd: 0, vectorCount: 0, hits: []
        )
        try db.logRecall(&second)

        let events = try db.recentRecallEvents()
        #expect(events.count == 2)
        #expect(events.first?.prompt == "later prompt") // newest first
        let stored = try #require(events.last)
        #expect(stored.cwd == "/tmp/proj")
        #expect(stored.hits.count == 2)
        #expect(stored.hits[0].injected)
        #expect(stored.hits[0].matchedAllKeywords)
        #expect(!stored.hits[1].confident)
        #expect(stored.hits[1].sim == 0.51)
    }

    @Test func insertPrunesTo500KeepingNewest() throws {
        let db = try tempDB()
        for i in 1...510 {
            var event = RecallEvent(
                sessionId: "s", cwd: nil, prompt: "p\(i)",
                vectorMean: 0, vectorStd: 0, vectorCount: 0, hits: []
            )
            try db.logRecall(&event)
        }
        let count = try db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recall_event")
        }
        #expect(count == 500)
        let events = try db.recentRecallEvents(500)
        #expect(events.first?.prompt == "p510")
        #expect(events.last?.prompt == "p11") // p1...p10 pruned
    }
}
