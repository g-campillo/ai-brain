import Foundation
import Testing
@testable import BrainKit

@Suite struct ExportTests {
    @Test func exportsEveryNoteAsMarkdownWithFrontmatter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try BrainDatabase.open(atPath: dir.appendingPathComponent("brain.db").path)

        var active = Note(type: .troubleshooting, title: "Publish stuck: stale lock", body: "Clear the lock row.", project: "etk-sandbox", tags: ["publish", "lock"])
        var archived = Note(type: .learning, title: "County-b is on 7.4", body: "Check 7.4 docs.", status: .archived)
        try db.save(&active)
        try db.save(&archived)

        let out = dir.appendingPathComponent("export")
        let count = try db.exportMarkdown(to: out)
        #expect(count == 2)

        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(files.count == 2)
        let activeFile = try #require(files.first { $0.contains("publish-stuck") })
        let text = try String(contentsOf: out.appendingPathComponent(activeFile), encoding: .utf8)
        #expect(text.hasPrefix("---\n"))
        #expect(text.contains("type: troubleshooting"))
        #expect(text.contains("project: etk-sandbox"))
        #expect(text.contains("tags: [publish, lock]"))
        #expect(text.contains("Clear the lock row."))

        // Idempotent re-export.
        #expect(try db.exportMarkdown(to: out) == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).count == 2)
    }
}
