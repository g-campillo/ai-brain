import Foundation
import FoundationModels

/// Turns a finished Claude Code session transcript into 0–n inbox note
/// candidates using the on-device Foundation Models LLM.
public enum Harvester {
    // MARK: - Transcript distillation (pure)

    /// Distills a Claude Code JSONL transcript into a speaker-labeled excerpt
    /// that fits the on-device model's small context window. Keeps user text
    /// and assistant prose (newest first when over budget); drops tool calls,
    /// tool results, and meta lines.
    public static func salientExcerpt(fromJSONL jsonl: String, budget: Int = 6000) -> String {
        struct Line: Decodable {
            struct Message: Decodable {
                struct Content: Decodable {
                    let type: String
                    let text: String?
                }
                let role: String?
                let content: [Content]?
            }
            // Envelope shape: {"type":"user","message":{"content":[{"type":"text",...}]}}
            let type: String?
            let message: Message?
            // Flat shape: {"role":"user","content":"..."}
            let role: String?
            let content: String?
        }

        var entries: [(speaker: String, text: String)] = []
        for raw in jsonl.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let line = try? JSONDecoder().decode(Line.self, from: data)
            else { continue }

            let speaker: String
            let text: String
            if let type = line.type, type == "user" || type == "assistant", let blocks = line.message?.content {
                speaker = type == "user" ? "USER" : "ASSISTANT"
                text = blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
            } else if let role = line.role, role == "user" || role == "assistant", let flat = line.content {
                speaker = role == "user" ? "USER" : "ASSISTANT"
                text = flat
            } else {
                continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            entries.append((speaker, text))
        }

        // Newest exchanges carry the resolution; keep them when over budget.
        var kept: [String] = []
        var used = 0
        for entry in entries.reversed() {
            let block = "\(entry.speaker): \(entry.text.prefix(1500))\n"
            if used + block.count > budget { continue }
            kept.append(block)
            used += block.count
        }
        return kept.reversed().joined()
    }

    // MARK: - On-device extraction

    @Generable
    struct Candidates {
        @Guide(description: "Durable, reusable notes extracted from the session. Empty if nothing worth remembering happened. Never more than 3.")
        var notes: [Candidate]
    }

    @Generable
    struct Candidate {
        @Guide(description: "Short, searchable title.")
        var title: String
        @Guide(description: "Symptom, root cause, and fix (or the fact itself), written for a reader with zero context about this session.")
        var body: String
        @Guide(description: "Exactly one of: troubleshooting, how-it-works, runbook, decision, glossary, learning, snippet.")
        var type: String
        @Guide(description: "Two to four lowercase keyword tags.")
        var tags: [String]
    }

    /// Returns inbox-status notes extracted from the transcript, or [] when the
    /// session held nothing durable. Throws if Foundation Models is unavailable.
    public static func harvest(transcriptJSONL: String, projectSlug: String?) async throws -> [Note] {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.appleIntelligenceNotEnabled):
            throw BrainError.foundationModelsUnavailable(reason: "Apple Intelligence is not enabled — turn it on in System Settings > Apple Intelligence & Siri to activate session harvesting")
        case .unavailable(.deviceNotEligible):
            throw BrainError.foundationModelsUnavailable(reason: "device not eligible for Apple Intelligence")
        case .unavailable(.modelNotReady):
            throw BrainError.foundationModelsUnavailable(reason: "model assets still downloading — try again later")
        case .unavailable(let other):
            throw BrainError.foundationModelsUnavailable(reason: "\(other)")
        }
        let excerpt = salientExcerpt(fromJSONL: transcriptJSONL)
        guard excerpt.count > 200 else { return [] } // nothing substantive happened

        let session = LanguageModelSession(instructions: """
            You extract durable knowledge from a coding-assistant session transcript. \
            Extract ONLY facts that will still be useful in future sessions: resolved issues \
            (symptom, root cause, fix), how systems work, environment quirks, decisions made, \
            reusable commands. NEVER extract session-specific chatter, plans, or half-finished work. \
            Most sessions contain nothing durable — returning zero notes is the normal outcome.
            """)
        let response = try await session.respond(
            to: "Transcript excerpt:\n\n\(excerpt)",
            generating: Candidates.self
        )

        return response.content.notes.prefix(3).map { candidate in
            Note(
                type: NoteType(rawValue: candidate.type) ?? .learning,
                title: candidate.title,
                body: candidate.body,
                project: projectSlug,
                tags: candidate.tags,
                source: .harvest,
                status: .inbox
            )
        }
    }
}
