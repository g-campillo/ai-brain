import ArgumentParser
import BrainKit
import Foundation

// MARK: - Shared hook plumbing

/// Hooks must never break the user's session: log and exit 0 on any failure.
func hookLog(_ message: String) {
    let url = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/brain.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct PromptHookInput: Decodable {
    let session_id: String
    let prompt: String
}

struct StopHookInput: Decodable {
    let session_id: String
    let transcript_path: String
    let cwd: String?
}

struct HookOutput: Encodable {
    struct Specific: Encodable {
        let hookEventName: String
        let additionalContext: String
    }
    let hookSpecificOutput: Specific
}

// MARK: - UserPromptSubmit: brain search --hook

extension SearchCommand {
    /// Reads UserPromptSubmit JSON on stdin; emits additionalContext JSON when the
    /// brain has high-confidence matches not already injected this session.
    func runPromptHook() async {
        do {
            let data = try FileHandle.standardInput.readToEnd() ?? Data()
            let input = try JSONDecoder().decode(PromptHookInput.self, from: data)
            let prompt = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard prompt.count >= 12, !prompt.hasPrefix("/") else { return } // trivial or slash command

            let db = try BrainDatabase.open()
            let embedder = try await Embedder.ready()
            var confident = try db.search(prompt, k: 5, embedder: embedder).highConfidenceHits()

            // Per-session dedupe: never inject the same note twice.
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("brain-hook-\(input.session_id)")
            let seen = Set((try? String(contentsOf: marker, encoding: .utf8))?
                .split(separator: "\n").compactMap { Int64($0) } ?? [])
            confident.removeAll { $0.note.id.map(seen.contains) ?? true }
            guard !confident.isEmpty else { return }

            let ids = seen.union(confident.compactMap(\.note.id))
            try? ids.map(String.init).joined(separator: "\n").write(to: marker, atomically: true, encoding: .utf8)

            let lines = confident.map { hit in
                "- [id \(hit.note.id ?? 0) · \(hit.note.type.rawValue)\(hit.note.site.map { " · \($0)" } ?? "")] \(hit.note.title): \(hit.snippet.replacingOccurrences(of: "\n", with: " ").prefix(200))"
            }
            let context = """
            <brain-recall>
            The user's persistent knowledge base has notes that look relevant to this prompt:
            \(lines.joined(separator: "\n"))
            Call the brain_get MCP tool with an id for full detail. Ignore notes that turn out to be irrelevant.
            </brain-recall>
            """
            let output = HookOutput(hookSpecificOutput: .init(hookEventName: "UserPromptSubmit", additionalContext: context))
            print(String(data: try JSONEncoder().encode(output), encoding: .utf8) ?? "")
            hookLog("prompt-hook: injected \(confident.count) note(s) for session \(input.session_id)")
        } catch {
            hookLog("prompt-hook failed: \(error)")
        }
    }
}

// MARK: - Stop: brain harvest

struct HarvestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harvest",
        abstract: "Stop-hook: distill durable learnings from the session into inbox notes."
    )

    /// Minimum new transcript bytes before a harvest is worth an inference pass.
    static let minNewBytes = 3000

    func run() async {
        do {
            let data = try FileHandle.standardInput.readToEnd() ?? Data()
            let input = try JSONDecoder().decode(StopHookInput.self, from: data)

            guard let jsonl = try? String(contentsOfFile: input.transcript_path, encoding: .utf8) else {
                hookLog("harvest: unreadable transcript \(input.transcript_path)")
                return
            }

            // Stop fires after EVERY turn; only harvest when enough new content exists.
            // Offset is in characters, consistently.
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("brain-harvest-\(input.session_id)")
            let offset = Int((try? String(contentsOf: marker, encoding: .utf8)) ?? "") ?? 0
            guard jsonl.count - offset >= Self.minNewBytes else { return }
            let newSlice = String(jsonl.suffix(jsonl.count - min(offset, jsonl.count)))
            try? String(jsonl.count).write(to: marker, atomically: true, encoding: .utf8)

            let slug = input.cwd.map { ($0 as NSString).lastPathComponent }
            var notes = try await Harvester.harvest(transcriptJSONL: newSlice, projectSlug: slug)
            guard !notes.isEmpty else {
                hookLog("harvest: nothing durable in session \(input.session_id)")
                return
            }

            let db = try BrainDatabase.open()
            let embedder = try await Embedder.ready()
            for i in notes.indices {
                try db.save(&notes[i])
                try db.indexEmbeddings(for: notes[i], using: embedder)
            }
            hookLog("harvest: \(notes.count) inbox candidate(s) from session \(input.session_id): \(notes.map(\.title).joined(separator: " | "))")
        } catch {
            hookLog("harvest failed: \(error)")
        }
    }
}
