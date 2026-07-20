import Foundation
import Testing
@testable import BrainKit

@Suite struct OverviewTests {
    @Test func overviewSummarizesCountsCoverageAndRecents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try BrainDatabase.open(atPath: dir.appendingPathComponent("brain.db").path)

        var kept = Note(type: .sessionSummary, title: "Fixed the publish worker", body: "x", project: "ai-brain")
        var other = Note(type: .troubleshooting, title: "Login loop", body: "y", project: "etk")
        var archived = Note(type: .runbook, title: "Retired runbook", body: "z", status: .archived)
        try db.save(&kept)
        try db.save(&other)
        try db.save(&archived)
        try db.saveEmbeddings(noteID: kept.id!, vectors: [[1, 2]], modelVersion: "m")

        let text = try db.overview()
        #expect(text.contains("2 active, 1 archived"))
        #expect(text.contains("embedded: 1/2"))
        #expect(text.contains("session-summary: 1"))
        #expect(text.contains("ai-brain: 1"))
        #expect(text.contains("Fixed the publish worker"))
        // Archived notes stay out of type/project breakdowns and recents.
        #expect(!text.contains("Retired runbook"))
        #expect(!text.contains("runbook: 1"))
    }
}
