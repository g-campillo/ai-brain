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
            let result = try db.search(prompt, k: 5, embedder: embedder)
            let confidentIDs = Set(result.highConfidenceHits().compactMap(\.note.id))

            // Per-session dedupe: never inject the same note twice.
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("brain-hook-\(input.session_id)")
            let seen = Set((try? String(contentsOf: marker, encoding: .utf8))?
                .split(separator: "\n").compactMap { Int64($0) } ?? [])
            let injected = result.hits.filter { hit in
                hit.note.id.map { confidentIDs.contains($0) && !seen.contains($0) } ?? false
            }

            // Log the decision (all candidates, gate + dedupe outcomes) before any
            // early return; logging must never break the hook.
            var event = RecallEvent(
                sessionId: input.session_id,
                cwd: input.cwd,
                prompt: prompt,
                vectorMean: result.vectorMean,
                vectorStd: result.vectorStd,
                vectorCount: result.vectorCount,
                hits: result.hits.compactMap { hit in
                    hit.note.id.map { id in
                        RecallEvent.Hit(
                            noteId: id,
                            title: hit.note.title,
                            rrf: hit.score,
                            sim: hit.vectorSimilarity,
                            matchedAllKeywords: hit.matchedAllKeywords,
                            confident: confidentIDs.contains(id),
                            injected: confidentIDs.contains(id) && !seen.contains(id)
                        )
                    }
                }
            )
            try? db.logRecall(&event)

            guard !injected.isEmpty else { return }

            let ids = seen.union(injected.compactMap(\.note.id))
            try? ids.map(String.init).joined(separator: "\n").write(to: marker, atomically: true, encoding: .utf8)

            let lines = injected.map { hit in
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
            hookLog("prompt-hook: injected \(injected.count) note(s) for session \(input.session_id)")
        } catch {
            hookLog("prompt-hook failed: \(error)")
        }
    }
}
