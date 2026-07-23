import CryptoKit
import Foundation
import Yams

/// The Obsidian vault is the brain's source of truth: one markdown file per note,
/// YAML frontmatter + body. The SQLite database is a rebuildable index over it.
public enum Vault {
    /// `$BRAIN_VAULT`, else `~/BrainVault`.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["BRAIN_VAULT"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("BrainVault", isDirectory: true)
    }

    /// A note read back off disk, with the hash used to detect content changes.
    public struct VaultFile: Sendable {
        public var note: Note
        public var url: URL
        public var contentHash: String
    }

    public struct Parsed: Sendable {
        public var note: Note   // `note.id` is nil for a file with no `id:` frontmatter
        public var hadID: Bool
    }

    public enum VaultError: Error, CustomStringConvertible {
        case unknownType(String)
        public var description: String {
            switch self { case .unknownType(let t): "unknown or missing note type '\(t)'" }
        }
    }

    // MARK: - Filenames

    public static func slug(_ title: String) -> String {
        let s = title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in if ch != "-" || out.last != "-" { out.append(ch) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "untitled" : String(s.prefix(60))
    }

    public static func filename(id: Int64, title: String) -> String { "\(id)-\(slug(title)).md" }

    // MARK: - Files

    public static func list(_ dir: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    public static func write(_ note: Note, to dir: URL = defaultURL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename(id: note.id ?? 0, title: note.title))
        try emit(note).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static func read(_ url: URL) throws -> VaultFile {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let text = String(decoding: data, as: UTF8.self)
        let fallback = url.deletingPathExtension().lastPathComponent
        let parsed = try parse(contents: text, fallbackTitle: fallback)
        return VaultFile(note: parsed.note, url: url, contentHash: hash)
    }

    // MARK: - Emit

    /// Deterministic, human-diffable frontmatter. The body is written verbatim;
    /// the title lives only in frontmatter (Chunker re-prefixes it for embeddings).
    public static func emit(_ note: Note) -> String {
        var lines = ["---"]
        if let id = note.id { lines.append("id: \(id)") }
        lines.append("title: \(quote(note.title))")
        lines.append("type: \(note.type.rawValue)")
        lines.append("status: \(note.status.rawValue)")
        lines.append("source: \(note.source.rawValue)")
        if let p = note.project { lines.append("project: \(quote(p))") }
        if let s = note.site { lines.append("site: \(quote(s))") }
        if let j = note.jiraKey { lines.append("jira: \(quote(j))") }
        if !note.tags.isEmpty {
            lines.append("tags:")
            lines += note.tags.map { "  - \(quote($0))" }
        }
        lines.append("created: \(iso.string(from: note.createdAt))")
        lines.append("updated: \(iso.string(from: note.updatedAt))")
        lines.append("---")
        var body = note.body
        while body.hasPrefix("\n") { body.removeFirst() }
        if !body.hasSuffix("\n") { body += "\n" }
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    // MARK: - Parse

    /// Split frontmatter from body and decode. Uses a real YAML parser because the
    /// frontmatter may have been hand-edited in Obsidian (quotes, unicode, lists).
    public static func parse(contents: String, fallbackTitle: String) throws -> Parsed {
        let lines = contents.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else {
            // No frontmatter at all: treat the whole file as body, filename as title.
            return Parsed(note: Note(type: .snippet, title: fallbackTitle, body: contents), hadID: false)
        }
        let frontmatter = lines[1..<close].joined(separator: "\n")
        var bodyLines = Array(lines[(close + 1)...])
        while bodyLines.first == "" { bodyLines.removeFirst() }
        while bodyLines.last == "" { bodyLines.removeLast() }
        let body = bodyLines.joined(separator: "\n")

        let dict = (try Yams.load(yaml: frontmatter) as? [String: Any]) ?? [:]

        guard let typeRaw = dict["type"] as? String else { throw VaultError.unknownType("nil") }
        guard let type = NoteType(rawValue: typeRaw) else { throw VaultError.unknownType(typeRaw) }

        let id = (dict["id"] as? Int).map(Int64.init)
        let created = date(dict["created"]) ?? Date()
        let note = Note(
            id: id,
            type: type,
            title: (dict["title"] as? String) ?? fallbackTitle,
            body: body,
            project: dict["project"] as? String,
            site: dict["site"] as? String,
            tags: stringList(dict["tags"]),
            jiraKey: dict["jira"] as? String,
            source: (dict["source"] as? String).flatMap(NoteSource.init(rawValue:)) ?? .manual,
            status: (dict["status"] as? String).flatMap(NoteStatus.init(rawValue:)) ?? .active,
            createdAt: created,
            updatedAt: date(dict["updated"]) ?? created
        )
        return Parsed(note: note, hadID: id != nil)
    }

    // MARK: - Helpers

    private static var iso: ISO8601DateFormatter { ISO8601DateFormatter() }

    /// Double-quote free-text scalars so colons, '#', and friends can't break YAML.
    private static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func stringList(_ any: Any?) -> [String] {
        if let list = any as? [Any] { return list.compactMap { $0 as? String } }
        if let one = any as? String { return one.isEmpty ? [] : [one] }
        return []
    }

    /// Yams decodes an unquoted ISO date to `Date`; a quoted one stays a `String`.
    private static func date(_ any: Any?) -> Date? {
        if let d = any as? Date { return d }
        if let s = any as? String { return iso.date(from: s) }
        return nil
    }
}
