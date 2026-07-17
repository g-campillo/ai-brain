import Foundation

extension BrainDatabase {
    /// SessionStart payload: project-context note(s) for a working directory plus
    /// the most recent related notes. Returns nil when the brain knows nothing
    /// about the project (the hook then injects nothing).
    ///
    /// A note's `project` may hold the directory's basename (slug) or a full path.
    public func brief(forProjectPath path: String, maxOther: Int = 3, maxChars: Int = 2000) throws -> String? {
        let slug = (path as NSString).lastPathComponent
        let projectNotes = try recent(50, filters: SearchFilters(project: slug))
            + (try recent(50, filters: SearchFilters(project: path)))
        guard !projectNotes.isEmpty else { return nil }

        let contexts = projectNotes.filter { $0.type == .projectContext }
        let others = projectNotes.filter { $0.type != .projectContext }.prefix(maxOther)

        var lines: [String] = ["# Brain: \(slug)"]
        for note in contexts {
            lines.append("## \(note.title)\n\(note.body)")
        }
        if !others.isEmpty {
            lines.append("## Recent notes for this project")
            for note in others {
                lines.append("- [\(note.type.rawValue)] \(note.title): \(note.body.prefix(200))")
            }
        }
        return String(lines.joined(separator: "\n").prefix(maxChars))
    }
}
