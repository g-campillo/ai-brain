import Foundation
import Observation

/// Drives one conversation with the headless `claude` CLI, which answers by
/// searching the brain through the already-registered brain MCP server.
@MainActor
@Observable
final class AskSession {
    struct Turn: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    private(set) var turns: [Turn] = []
    private(set) var isStreaming = false
    private(set) var status: String?
    private(set) var error: String?

    /// GUI-test hook (BRAIN_ASK_TEST): markdown-rich transcript exercising every
    /// MarkdownText block kind, without touching the claude CLI or the keyboard.
    /// BRAIN_ASK_TEST=short seeds one brief exchange (underfull-panel case).
    func seedCannedTranscript() {
        if ProcessInfo.processInfo.environment["BRAIN_ASK_TEST"] == "short" {
            turns = [
                Turn(role: .user, text: "where is the server.xml file stored"),
                Turn(role: .assistant, text: """
                    **server.xml** for the entellitrak sandbox lives at `config/server.xml` in the repo, \
                    which gets copied by the Dockerfile into the container at \
                    `/usr/local/tomcat/conf/server.xml` (image `tomcat:10.1-jdk17-temurin`) [id 27].

                    Related: there's no `datasource.xml` in 24.x — its successor is `context/entellitrak.xml`.
                    """),
            ]
            return
        }
        turns = [
            Turn(role: .user, text: "where is the server.xml file stored within an entellitrak container?"),
            Turn(role: .assistant, text: """
                **server.xml** is the global Tomcat config, so its location is standard Tomcat, \
                not app-specific — see [id 15 · etk-sandbox]:

                ```
                $CATALINA_BASE/conf/server.xml
                ```

                - In the etk-sandbox image `CATALINA_HOME=/usr/local/tomcat`, no separate base
                - The per-app context descriptor is `conf/Catalina/localhost/entellitrak.xml`
                - Real connector tuning happens here, not in `application.yml`

                > Most Spring `server.*` yml properties are dead in this WAR-on-Tomcat setup.
                """),
            Turn(role: .user, text: "show me a snippet to read it"),
            Turn(role: .assistant, text: """
                ```swift
                let path = "/usr/local/tomcat/conf/server.xml"
                let xml = try String(contentsOfFile: path, encoding: .utf8)
                print(xml.prefix(200))
                ```

                1. Resolve `$CATALINA_BASE` first (it can differ from `CATALINA_HOME`)
                2. Read the file
                3. Look for the `<Connector>` element
                """),
        ]
    }

    private var sessionId: String?
    private var process: Process?
    private var readTask: Task<Void, Never>?
    private var errTask: Task<Void, Never>?
    private var stderrTail = ""

    /// Resolved through a login shell: Finder-launched apps get a bare PATH, and
    /// the child needs the real PATH too (npm-installed claude shells out to node).
    nonisolated static let claude: (path: String, searchPath: String)? = {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Marker must be quoted: unquoted leading `=` triggers zsh equals expansion,
        // which fails to resolve `==BRAIN==` as a command and aborts the whole line.
        probe.arguments = ["-l", "-c", "echo '===BRAIN==='; command -v claude && printenv PATH"]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        // Dotfiles may echo noise before the marker; only trust what follows it.
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard let marker = lines.lastIndex(of: "===BRAIN==="), lines.count >= marker + 3 else {
            return nil
        }
        return (lines[marker + 1], lines[marker + 2])
    }()

    private static let systemPrompt = """
        You answer questions from the user's personal "brain" knowledge base. \
        Always call brain_search first (and brain_get for full note bodies) before answering. \
        Be concise. Cite supporting notes inline like [id 42 · title]. \
        Use markdown lists and fenced code blocks when they help; avoid headings unless the answer is long. \
        If the brain has nothing relevant, say so briefly.
        """

    func ask(_ question: String, model: String) {
        cancelProcess() // kill any in-flight run; transcript stays
        error = nil
        turns.append(Turn(role: .user, text: question))
        turns.append(Turn(role: .assistant, text: ""))
        isStreaming = true
        status = "Thinking…"

        guard let claude = Self.claude else {
            fail("claude CLI not found — is Claude Code installed?")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude.path)
        var args = [
            "-p", "--output-format", "stream-json", "--include-partial-messages", "--verbose",
            "--model", model,
            "--tools", "", // no built-in tools; MCP tools unaffected
            "--allowedTools", "mcp__brain__brain_search,mcp__brain__brain_get,mcp__brain__brain_recent,mcp__brain__brain_overview",
            "--append-system-prompt", Self.systemPrompt,
            "--max-turns", "16",
        ]
        if let sessionId { args += ["--resume", sessionId] }
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = claude.searchPath
        p.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        do {
            try p.run()
        } catch {
            fail("Failed to launch claude: \(error.localizedDescription)")
            return
        }
        process = p
        stderrTail = ""
        stdin.fileHandleForWriting.write(Data(question.utf8))
        try? stdin.fileHandleForWriting.close() // claude waits forever on open stdin

        // Tasks inherit MainActor from the class; awaits suspend, never block.
        // Tasks inherit MainActor from the class; chunks arrive via AsyncStream.
        let stdoutChunks = Self.chunks(from: stdout.fileHandleForReading)
        let stderrChunks = Self.chunks(from: stderr.fileHandleForReading)
        readTask = Task { [weak self] in
            var buffer = Data()
            for await chunk in stdoutChunks {
                if Task.isCancelled { break } // a newer ask took over
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    self?.handle(line)
                }
            }
            if !buffer.isEmpty, !Task.isCancelled {
                self?.handle(String(decoding: buffer, as: UTF8.self))
            }
            await self?.finish(for: p)
        }
        // Drain stderr concurrently so a chatty claude can't fill the pipe and deadlock.
        errTask = Task { [weak self] in
            for await chunk in stderrChunks {
                if Task.isCancelled { break }
                guard let self else { return }
                self.stderrTail = String(
                    (self.stderrTail + String(decoding: chunk, as: UTF8.self)).suffix(2000))
            }
        }
    }

    /// FileHandle.bytes.lines loses data on subprocess pipes: with a slow consumer it
    /// truncated the stream at the 64KB pipe-buffer boundary and reported a spurious
    /// EOF (observed live; claude had written the full stream and exited 0). The
    /// readabilityHandler callback is the reliable pipe API — frame on \n ourselves,
    /// which also avoids AsyncLineSequence splitting on U+2028/U+2029 inside JSON.
    private nonisolated static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty { // EOF
                    fh.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }

    func cancel() {
        cancelProcess()
    }

    // MARK: - stream-json events

    private struct Event: Decodable {
        let type: String
        let session_id: String?
        let is_error: Bool?
        let result: String?
        let event: StreamEvent?
        let message: Message?

        struct StreamEvent: Decodable {
            let type: String?
            let delta: Delta?
        }
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
        struct Message: Decodable {
            let content: [Block]?
        }
        struct Block: Decodable {
            let type: String?
            let name: String?
        }
    }

    private func handle(_ line: String) {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else {
            return // tolerate unknown/partial lines
        }
        if let sid = event.session_id { sessionId = sid } // latest wins: --resume forks a new id
        switch event.type {
        case "stream_event":
            if event.event?.delta?.type == "text_delta", let text = event.event?.delta?.text,
                !turns.isEmpty {
                status = nil
                turns[turns.count - 1].text += text
            }
        case "assistant":
            if let tool = event.message?.content?.first(where: { $0.type == "tool_use" })?.name {
                status = tool.hasPrefix("mcp__brain") ? "Searching brain…" : "Working…"
            }
        case "result":
            if event.is_error == true {
                error = (event.result?.isEmpty == false ? event.result : nil)
                    ?? "claude returned an error"
            } else if let final = event.result, !turns.isEmpty {
                // Authoritative final answer; supersedes any pre-tool narration deltas.
                turns[turns.count - 1].text = final
            }
            status = nil
            isStreaming = false
        default:
            break // system/init, hooks, user tool_results, rate_limit_event, …
        }
    }

    private func finish(for p: Process) async {
        guard process === p else { return } // a newer ask owns the session now
        await errTask?.value // stderr fully drained before we read the tail
        p.waitUntilExit()
        process = nil
        if isStreaming { // exited without a result event: auth failure, crash, SIGTERM
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            fail(tail.isEmpty ? "claude exited unexpectedly" : tail)
        }
    }

    private func fail(_ message: String) {
        error = message
        isStreaming = false
        status = nil
    }

    private func cancelProcess() {
        readTask?.cancel()
        errTask?.cancel()
        readTask = nil
        errTask = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        isStreaming = false
        status = nil
    }
}
