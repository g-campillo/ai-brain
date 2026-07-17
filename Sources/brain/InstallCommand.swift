import ArgumentParser
import BrainKit
import Foundation

/// Idempotently wires the brain into Claude Code: MCP registration in
/// ~/.claude.json and the three hooks in ~/.claude/settings.json.
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
        print("""
        brain installed:
          MCP server  → \(home)/.claude.json (mcpServers.brain)
          hooks       → \(home)/.claude/settings.json (SessionStart, UserPromptSubmit, Stop)
          binary      → \(binPath)

        Optional: add this line to your global CLAUDE.md for deliberate mid-task recall:
          "Before debugging an unfamiliar error, call brain_search — the issue may already be solved."
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
        hooks["Stop"] = merged("Stop", adding: [
            entry(matcher: nil, command: "\(binPath) harvest", timeout: 120, async: true),
        ])

        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
