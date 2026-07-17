import ArgumentParser
import BrainKit
import Foundation
import MCP

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run the stdio MCP server Claude connects to."
    )

    func run() async throws {
        let db = try BrainDatabase.open()
        let embedder = try await Embedder.ready()

        let server = Server(
            name: "brain",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: BrainTools.definitions)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                let text = try BrainTools.call(params, db: db, embedder: embedder)
                return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
            } catch {
                return .init(content: [.text(text: "error: \(error)", annotations: nil, _meta: nil)], isError: true)
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}

enum BrainTools {
    static let definitions: [Tool] = [
        Tool(
            name: "brain_search",
            description: """
            Search Gio's persistent knowledge base (past issue resolutions, runbooks, \
            how-things-work notes, project context). Use before debugging anything that \
            might have happened before, and whenever a site/env/tool is unfamiliar.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("What to look for; natural language works (semantic + keyword search).")]),
                    "k": .object(["type": .string("integer"), "description": .string("Max results (default 5).")]),
                    "type": .object(["type": .string("string"), "description": .string("Optional note type filter: \(NoteType.allCases.map(\.rawValue).joined(separator: ", ")).")]),
                    "project": .object(["type": .string("string"), "description": .string("Optional project slug filter.")]),
                    "site": .object(["type": .string("string"), "description": .string("Optional site/env filter.")]),
                    "tag": .object(["type": .string("string"), "description": .string("Optional tag filter.")]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        Tool(
            name: "brain_get",
            description: "Fetch the full text of one note by id (ids come from brain_search/brain_recent).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("integer"), "description": .string("Note id.")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "brain_save",
            description: """
            Save a durable note to the knowledge base. Use when the user says "remember this" \
            or after resolving a non-obvious issue worth reusing. Write it for a future session \
            with zero context: symptom, root cause, fix.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("Short, searchable title.")]),
                    "body": .object(["type": .string("string"), "description": .string("Markdown body: symptom, root cause, fix / content.")]),
                    "type": .object(["type": .string("string"), "description": .string("One of: \(NoteType.allCases.map(\.rawValue).joined(separator: ", ")).")]),
                    "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Lowercase keywords.")]),
                    "project": .object(["type": .string("string"), "description": .string("Project slug (directory basename) this belongs to.")]),
                    "site": .object(["type": .string("string"), "description": .string("Client site/env this applies to.")]),
                    "jira_key": .object(["type": .string("string"), "description": .string("Related Jira ticket, e.g. ABC-123.")]),
                ]),
                "required": .array([.string("title"), .string("body"), .string("type")]),
            ])
        ),
        Tool(
            name: "brain_recent",
            description: "List the most recently updated notes (optionally filtered by type/project/site/tag).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "n": .object(["type": .string("integer"), "description": .string("Max notes (default 10).")]),
                    "type": .object(["type": .string("string"), "description": .string("Optional note type filter.")]),
                    "project": .object(["type": .string("string"), "description": .string("Optional project filter.")]),
                    "site": .object(["type": .string("string"), "description": .string("Optional site filter.")]),
                    "tag": .object(["type": .string("string"), "description": .string("Optional tag filter.")]),
                ]),
            ])
        ),
    ]

    static func call(_ params: CallTool.Parameters, db: BrainDatabase, embedder: Embedder) throws -> String {
        let args = params.arguments ?? [:]
        switch params.name {
        case "brain_search":
            guard let query = args["query"]?.stringValue else { throw ToolError.missing("query") }
            let hits = try db.search(query, k: args["k"]?.intValue ?? 5, filters: filters(from: args), embedder: embedder)
            guard !hits.isEmpty else { return "No notes found for '\(query)'." }
            return hits.map { hit in
                "[id \(hit.note.id ?? 0) · \(hit.note.type.rawValue)\(hit.note.site.map { " · \($0)" } ?? "")] \(hit.note.title)\n  \(hit.snippet.replacingOccurrences(of: "\n", with: " "))"
            }.joined(separator: "\n")

        case "brain_get":
            guard let id = args["id"]?.intValue else { throw ToolError.missing("id") }
            guard let note = try db.note(id: Int64(id)) else { return "No note with id \(id)." }
            return render(note)

        case "brain_save":
            guard let title = args["title"]?.stringValue else { throw ToolError.missing("title") }
            guard let body = args["body"]?.stringValue else { throw ToolError.missing("body") }
            guard let rawType = args["type"]?.stringValue, let type = NoteType(rawValue: rawType) else {
                throw ToolError.missing("type (one of \(NoteType.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            var note = Note(
                type: type,
                title: title,
                body: body,
                project: args["project"]?.stringValue,
                site: args["site"]?.stringValue,
                tags: args["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                jiraKey: args["jira_key"]?.stringValue
            )
            try db.save(&note)
            try db.indexEmbeddings(for: note, using: embedder)
            return "Saved note \(note.id ?? 0): \(title)"

        case "brain_recent":
            let notes = try db.recent(args["n"]?.intValue ?? 10, filters: filters(from: args))
            guard !notes.isEmpty else { return "No notes yet." }
            return notes.map { "[id \($0.id ?? 0) · \($0.type.rawValue)] \($0.title)" }.joined(separator: "\n")

        default:
            throw ToolError.unknownTool(params.name)
        }
    }

    private static func filters(from args: [String: Value]) -> SearchFilters {
        SearchFilters(
            type: args["type"]?.stringValue.flatMap(NoteType.init(rawValue:)),
            project: args["project"]?.stringValue,
            site: args["site"]?.stringValue,
            tag: args["tag"]?.stringValue
        )
    }

    private static func render(_ note: Note) -> String {
        var head = "# \(note.title)\ntype: \(note.type.rawValue)"
        if let project = note.project { head += " · project: \(project)" }
        if let site = note.site { head += " · site: \(site)" }
        if !note.tags.isEmpty { head += " · tags: \(note.tags.joined(separator: ", "))" }
        if let jira = note.jiraKey { head += " · jira: \(jira)" }
        return head + "\n\n" + note.body
    }

    enum ToolError: Error, CustomStringConvertible {
        case missing(String)
        case unknownTool(String)

        var description: String {
            switch self {
            case .missing(let what): "missing or invalid argument: \(what)"
            case .unknownTool(let name): "unknown tool: \(name)"
            }
        }
    }
}
