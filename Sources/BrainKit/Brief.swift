import Foundation

extension BrainDatabase {
    /// SessionStart payload: the project-context note(s) for a working directory.
    /// Returns nil when the project has none (the hook then injects nothing).
    /// Everything else reaches sessions on demand via recall and brain_search.
    ///
    /// A note's `project` may hold the directory's basename (slug) or a full path.
    public func brief(forProjectPath path: String, maxChars: Int = 2000) throws -> String? {
        let slug = (path as NSString).lastPathComponent
        let projectNotes = try recent(50, filters: SearchFilters(project: slug))
            + (try recent(50, filters: SearchFilters(project: path)))
        let contexts = projectNotes.filter { $0.type == .projectContext }
        guard !contexts.isEmpty else { return nil }

        var lines: [String] = ["# Brain: \(slug)"]
        for note in contexts {
            lines.append("## \(note.title)\n\(note.body)")
        }
        return String(lines.joined(separator: "\n").prefix(maxChars))
    }
}
