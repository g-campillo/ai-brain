import Foundation
import GRDB

extension BrainDatabase {
    /// Dumps every note (all statuses) as `<id>-<slug>.md` with YAML frontmatter.
    /// Lock-in insurance: the brain's contents are always one command away from
    /// plain files any tool can read.
    @discardableResult
    public func exportMarkdown(to dir: URL) throws -> Int {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notes = try pool.read { db in try Note.order(sql: "id").fetchAll(db) }
        for note in notes {
            var front = [
                "---",
                "type: \(note.type.rawValue)",
                "status: \(note.status.rawValue)",
                "source: \(note.source.rawValue)",
            ]
            if let project = note.project { front.append("project: \(project)") }
            if let site = note.site { front.append("site: \(site)") }
            if let jira = note.jiraKey { front.append("jira: \(jira)") }
            if !note.tags.isEmpty { front.append("tags: [\(note.tags.joined(separator: ", "))]") }
            front.append("created: \(ISO8601DateFormatter().string(from: note.createdAt))")
            front.append("updated: \(ISO8601DateFormatter().string(from: note.updatedAt))")
            front.append("---")

            let slug = note.title.lowercased()
                .map { $0.isLetter || $0.isNumber ? $0 : "-" }
                .reduce(into: "") { out, ch in
                    if ch != "-" || out.last != "-" { out.append(ch) }
                }
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let name = "\(note.id ?? 0)-\(slug.prefix(60)).md"
            let content = front.joined(separator: "\n") + "\n\n# \(note.title)\n\n\(note.body)\n"
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return notes.count
    }
}
