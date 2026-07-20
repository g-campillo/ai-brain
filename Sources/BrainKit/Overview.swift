import Foundation
import GRDB

extension BrainDatabase {
    /// One-screen snapshot of the knowledge base: totals, breakdowns, embedding
    /// coverage, recent notes. Deliberately embedder-free (coverage counts any
    /// model's vectors) so it stays instant; `brain doctor` reports the
    /// model-precise staleness number.
    public func overview() throws -> String {
        let (statusCounts, typeCounts, projectCounts, embedded) = try pool.read { db in
            (
                try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS c FROM note GROUP BY status"),
                try Row.fetchAll(db, sql: """
                    SELECT type, COUNT(*) AS c FROM note WHERE status = 'active'
                    GROUP BY type ORDER BY c DESC, type
                    """),
                try Row.fetchAll(db, sql: """
                    SELECT COALESCE(project, '(none)') AS p, COUNT(*) AS c FROM note
                    WHERE status = 'active' GROUP BY p ORDER BY c DESC, p
                    """),
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT e.noteId) FROM embedding e
                    JOIN note n ON n.id = e.noteId WHERE n.status = 'active'
                    """) ?? 0
            )
        }
        var active = 0, archived = 0
        for row in statusCounts {
            switch row["status"] as String? {
            case "active": active = row["c"]
            case "archived": archived = row["c"]
            default: break
            }
        }

        var lines = ["# Brain overview", "notes: \(active) active, \(archived) archived · embedded: \(embedded)/\(active)"]
        if !typeCounts.isEmpty {
            lines.append("\n## By type")
            lines += typeCounts.map { "\($0["type"] as String? ?? "?"): \($0["c"] as Int? ?? 0)" }
        }
        if !projectCounts.isEmpty {
            lines.append("\n## By project")
            lines += projectCounts.map { "\($0["p"] as String? ?? "?"): \($0["c"] as Int? ?? 0)" }
        }
        let recentNotes = try recent(10)
        if !recentNotes.isEmpty {
            lines.append("\n## Recent")
            lines += recentNotes.map { "[id \($0.id ?? 0) · \($0.type.rawValue)] \($0.title)" }
        }
        return lines.joined(separator: "\n")
    }
}
