import ArgumentParser
import BrainKit
import Foundation

/// Idempotently wires the brain into Claude Code: MCP registration in
/// ~/.claude.json, the two hooks in ~/.claude/settings.json, the /brain-save
/// skill, and the managed recall-rule block in ~/.claude/CLAUDE.md.
struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Register the MCP server and Claude Code hooks (idempotent)."
    )

    @Option(help: "Home directory override (testing).") var home: String = NSHomeDirectory()

    func run() async throws {
        let binPath = Self.resolvedBinaryPath()
        try installMCP(binPath: binPath)
        try installHooks(binPath: binPath)
        try installSkill()
        try installGlobalRule()
        print("""
        brain installed:
          MCP server  → \(home)/.claude.json (mcpServers.brain)
          hooks       → \(home)/.claude/settings.json (SessionStart, UserPromptSubmit)
          /brain-save → \(home)/.claude/skills/brain-save/SKILL.md
          recall rule → \(home)/.claude/CLAUDE.md (managed brain block)
          binary      → \(binPath)
        """)
    }

    static func resolvedBinaryPath() -> String {
        let argv0 = CommandLine.arguments[0]
        if argv0.hasPrefix("/") { return argv0 }
        return FileManager.default.currentDirectoryPath + "/" + argv0
    }

    private func installMCP(binPath: String) throws {
        let url = URL(fileURLWithPath: "\(home)/.claude.json")
        var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["brain"] = ["type": "stdio", "command": binPath, "args": ["mcp"], "env": [:]] as [String: Any]
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func installHooks(binPath: String) throws {
        let dir = URL(fileURLWithPath: "\(home)/.claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        func entry(matcher: String?, command: String, timeout: Int, async: Bool = false) -> [String: Any] {
            var hook: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
            if async { hook["async"] = true }
            var entry: [String: Any] = ["hooks": [hook]]
            if let matcher { entry["matcher"] = matcher }
            return entry
        }

        /// Drop any prior brain entries (allows path changes on reinstall), keep others.
        func merged(_ event: String, adding new: [[String: Any]]) -> [[String: Any]] {
            let existing = (hooks[event] as? [[String: Any]] ?? []).filter { entry in
                let cmds = (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
                return !cmds.contains { $0.contains("/brain ") || $0.contains("brain mcp") }
            }
            return existing + new
        }

        hooks["SessionStart"] = merged("SessionStart", adding: [
            entry(matcher: "startup", command: "\(binPath) brief --cwd \"$CLAUDE_PROJECT_DIR\"", timeout: 20),
            entry(matcher: "clear", command: "\(binPath) brief --cwd \"$CLAUDE_PROJECT_DIR\"", timeout: 20),
        ])
        hooks["UserPromptSubmit"] = merged("UserPromptSubmit", adding: [
            entry(matcher: nil, command: "\(binPath) search --hook", timeout: 15),
        ])
        // Capture is now the explicit /brain-save skill; purge the retired Stop harvest hook.
        let stopKept = merged("Stop", adding: [])
        if stopKept.isEmpty {
            hooks["Stop"] = nil
        } else {
            hooks["Stop"] = stopKept
        }

        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// User-level skill: overwriting on every install keeps it current with the binary.
    private func installSkill() throws {
        let dir = URL(fileURLWithPath: "\(home)/.claude/skills/brain-save")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.skillMarkdown.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    /// Marker-delimited block in the user's global CLAUDE.md; their own content is never touched.
    private func installGlobalRule() throws {
        let url = URL(fileURLWithPath: "\(home)/.claude/CLAUDE.md")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated: String
        if let start = existing.range(of: Self.ruleBegin),
           let end = existing.range(of: Self.ruleEnd),
           start.lowerBound <= end.lowerBound {
            updated = existing.replacingCharacters(in: start.lowerBound..<end.upperBound, with: Self.ruleBlock)
        } else if existing.isEmpty {
            updated = Self.ruleBlock + "\n"
        } else {
            updated = existing + "\n" + Self.ruleBlock + "\n"
        }
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    static let ruleBegin = "<!-- brain:begin -->"
    private static let ruleEnd = "<!-- brain:end -->"
    private static let ruleBlock = """
    <!-- brain:begin -->
    ## Brain (persistent memory)
    When starting a nontrivial task (bug, feature, troubleshooting), first run 1-3 brain_search queries across the WHOLE brain — no project filter — using distinctive terms: exact error text, symptoms, symbol/tech names. brain_get promising ids; a prior session may have already solved this. To save this session's learnings, the user runs /brain-save.
    <!-- brain:end -->
    """

    static let skillMarkdown = """
    ---
    name: brain-save
    description: Save one structured summary note of this session to the brain (persistent memory). Only run when the user explicitly invokes /brain-save.
    disable-model-invocation: true
    ---

    Write ONE markdown summary of this ENTIRE session and save it with the `brain_save` MCP tool. There is no approval step — the note is live and searchable the moment it is saved.

    **Before saving**: run 1-2 `brain_search` queries for this session's topic and project. If an existing note already covers it (especially a prior session-summary for the same workstream), prefer `brain_update` over a duplicate: append an addendum (`body_mode: "append"`), patch stale facts, and close out `## Follow-ups` items this session completed. Save a new note only when the session is genuinely new ground.

    **Title**: one specific, task-shaped sentence naming the concrete outcome (e.g. "Fixed publish worker OOM by capping batch size at 500"). Never generic ("Session summary", "Misc work").

    **Body**: markdown using these `##` sections, in order, skipping any with nothing to say. Keep each section tight — every section is embedded separately for semantic search, so padding dilutes recall. Pack in distinctive identifiers: exact error strings, function/type names, file paths, hostnames, config keys, ticket ids — future keyword searches match on precisely these.

    - `## Goal` — what this session set out to do and why
    - `## What was done` — the outcome, with key file paths
    - `## How it works` — mechanism and key files/symbols someone would need to pick this up later
    - `## Root cause` — debugging sessions only: symptom (exact error text) → cause → fix
    - `## Gotchas & learnings` — surprises, wrong assumptions, environment quirks
    - `## Verification` — what was run and what proved it works
    - `## Follow-ups` — deferred work and known ceilings

    **brain_save arguments**: `type` = "session-summary" · `project` = basename of the current working directory (e.g. /Users/gio/projects/ai-brain → "ai-brain") · `tags` = 3-5 lowercase topic/tech keywords · `jira_key` when a ticket was involved · `site` when the work targeted a specific site/env.

    Write for a future session with zero context. After saving, confirm with the note id and title. If the session was trivial or exploratory with nothing durable, say so and save nothing.
    """
}
