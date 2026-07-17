import Foundation
import Testing
@testable import BrainKit

@Suite struct RecentAndBriefTests {
    private func tempDB() throws -> BrainDatabase {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try BrainDatabase.open(atPath: dir.appendingPathComponent("brain.db").path)
    }

    @Test func recentReturnsNewestActiveFirstAndSkipsNonActive() throws {
        let db = try tempDB()
        var first = Note(type: .snippet, title: "oldest", body: "a")
        var second = Note(type: .snippet, title: "middle", body: "b")
        var inboxed = Note(type: .learning, title: "pending", body: "c", status: .inbox)
        var third = Note(type: .snippet, title: "newest", body: "d")
        try db.save(&first)
        try db.save(&second)
        try db.save(&inboxed)
        try db.save(&third)

        let recent = try db.recent(2)
        #expect(recent.map(\.title) == ["newest", "middle"])

        let all = try db.recent(10)
        #expect(!all.contains { $0.status != .active })
    }

    @Test func briefMatchesProjectSlugFromPathAndIncludesRecentRelated() throws {
        let db = try tempDB()
        var context = Note(
            type: .projectContext,
            title: "etk-sandbox overview",
            body: "Maven multi-module ETK project. Deploy with ./deploy.sh to the sandbox env.",
            project: "etk-sandbox"
        )
        var related = Note(
            type: .troubleshooting,
            title: "Sandbox deploy 403",
            body: "Nexus token expired; refresh with vault login.",
            project: "etk-sandbox"
        )
        var unrelated = Note(type: .runbook, title: "Other project note", body: "x", project: "vpn")
        try db.save(&context)
        try db.save(&related)
        try db.save(&unrelated)

        let brief = try #require(try db.brief(forProjectPath: "/Users/gcampillo/projects/etk-sandbox"))
        #expect(brief.contains("etk-sandbox overview"))
        #expect(brief.contains("Maven multi-module"))
        #expect(brief.contains("Sandbox deploy 403"))
        #expect(!brief.contains("Other project note"))

        #expect(try db.brief(forProjectPath: "/somewhere/never-seen") == nil)
    }
}
