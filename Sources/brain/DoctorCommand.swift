import ArgumentParser
import BrainKit
import Foundation

/// Verifies the whole install chain: MCP registration, hooks, skill, recall
/// rule, database, embedding model, coverage, and recent hook errors.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check the brain's Claude Code wiring and data health."
    )

    @Option(help: "Home directory override (testing).") var home: String = NSHomeDirectory()

    func run() async throws {
        var failed = false
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failed = true }
        }

        let binPath = InstallCommand.resolvedBinaryPath()

        // 1. MCP registration in ~/.claude.json
        let claudeJSON = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude.json"))
        )) as? [String: Any] ?? [:]
        let mcpCommand = ((claudeJSON["mcpServers"] as? [String: Any])?["brain"] as? [String: Any])?["command"] as? String
        switch mcpCommand {
        case nil:
            check("MCP server registered", false, "no mcpServers.brain in ~/.claude.json — run brain install")
        case binPath:
            check("MCP server registered", true, binPath)
        case let other?:
            check("MCP server registered", false, "registered \(other), running \(binPath) — re-run make install")
        }

        // 2. Hooks in ~/.claude/settings.json
        let settings = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude/settings.json"))
        )) as? [String: Any] ?? [:]
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        func hookCommands(_ event: String) -> [String] {
            (hooks[event] as? [[String: Any]] ?? []).flatMap { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
        }
        check("SessionStart hook", hookCommands("SessionStart").contains { $0.contains("\(binPath) brief") },
              "brain brief --cwd on startup+clear")
        check("UserPromptSubmit hook", hookCommands("UserPromptSubmit").contains { $0.contains("\(binPath) search --hook") },
              "brain search --hook recall")

        // 3. /brain-save skill current
        let skill = try? String(
            contentsOf: URL(fileURLWithPath: "\(home)/.claude/skills/brain-save/SKILL.md"), encoding: .utf8)
        let skillOK = skill == InstallCommand.skillMarkdown
        check("/brain-save skill current", skillOK,
              skillOK ? "" : skill == nil ? "missing — run brain install" : "stale — re-run brain install")

        // 4. Recall rule block in ~/.claude/CLAUDE.md
        let claudeMD = (try? String(contentsOf: URL(fileURLWithPath: "\(home)/.claude/CLAUDE.md"), encoding: .utf8)) ?? ""
        check("recall rule in CLAUDE.md", claudeMD.contains(InstallCommand.ruleBegin))

        // 5. Database opens (open migrates to head) + integrity
        var db: BrainDatabase?
        do {
            let opened = try BrainDatabase.open()
            let integrity = try await opened.pool.read { db in
                try String.fetchOne(db, sql: "PRAGMA quick_check")
            }
            check("database", integrity == "ok", BrainDatabase.defaultPath)
            db = opened
        } catch {
            check("database", false, "\(BrainDatabase.defaultPath): \(error)")
        }

        // 6-7. Embedding model + coverage
        do {
            let embedder = try await Embedder.ready()
            check("embedding model", true, embedder.modelVersion)
            if let db {
                let stale = try db.notesNeedingEmbedding(modelVersion: embedder.modelVersion).count
                check("embeddings current", stale == 0,
                      stale == 0 ? "" : "\(stale) note(s) need embedding — run brain index")
            }
        } catch {
            check("embedding model", false, "\(error)")
        }

        // 8. Hook failures in the last day
        let log = (try? String(contentsOf: URL(fileURLWithPath: "\(home)/Library/Logs/brain.log"), encoding: .utf8)) ?? ""
        let cutoff = Date().addingTimeInterval(-86_400)
        let formatter = ISO8601DateFormatter()
        let recentFailures = log.split(separator: "\n").filter { line in
            guard line.hasPrefix("["), let end = line.firstIndex(of: "]"),
                  let stamp = formatter.date(from: String(line[line.index(after: line.startIndex)..<end]))
            else { return false }
            return stamp > cutoff && line.contains("fail")
        }.count
        check("hook errors (24h)", recentFailures == 0,
              recentFailures == 0 ? "" : "\(recentFailures) failure line(s) in ~/Library/Logs/brain.log")

        if failed { throw ExitCode.failure }
    }
}
