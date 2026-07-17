import Foundation
import Testing
@testable import BrainKit

@Suite struct HarvesterExcerptTests {
    private func line(_ type: String, _ text: String) -> String {
        """
        {"type":"\(type)","message":{"role":"\(type)","content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    @Test func extractsUserAndAssistantTextSkippingNoise() {
        let jsonl = [
            #"{"type":"summary","summary":"irrelevant meta line"}"#,
            line("user", "the publish job hangs on county-a"),
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            line("assistant", "Found it: stale scheduler lock row. Clearing it fixed the publish."),
        ].joined(separator: "\n")

        let excerpt = Harvester.salientExcerpt(fromJSONL: jsonl)
        #expect(excerpt.contains("publish job hangs"))
        #expect(excerpt.contains("stale scheduler lock"))
        #expect(!excerpt.contains("tool_use"))
        #expect(!excerpt.contains("irrelevant meta line"))
        // Speaker labels so the model can follow the exchange.
        #expect(excerpt.contains("USER:"))
        #expect(excerpt.contains("ASSISTANT:"))
    }

    @Test func respectsBudgetKeepingNewestAssistantText() {
        let old = line("assistant", String(repeating: "old ", count: 800))
        let recent = line("assistant", "the final resolution: rotate the cert")
        let jsonl = [line("user", "help"), old, recent].joined(separator: "\n")

        let excerpt = Harvester.salientExcerpt(fromJSONL: jsonl, budget: 600)
        #expect(excerpt.count <= 600)
        #expect(excerpt.contains("final resolution"))
    }

    @Test func malformedLinesAreIgnored() {
        let jsonl = ["not json at all", "{\"type\":\"user\"}", line("user", "real content")].joined(separator: "\n")
        let excerpt = Harvester.salientExcerpt(fromJSONL: jsonl)
        #expect(excerpt.contains("real content"))
    }

    @Test func parsesEnvelopeWithPlainStringContent() {
        // Real Claude Code transcripts: typed user prompts have message.content as a
        // STRING; assistant messages use block arrays. Both must be captured.
        let jsonl = [
            #"{"type":"user","message":{"role":"user","content":"why is the exporter dropping rows"}}"#,
            line("assistant", "Because the drain interval exceeds the TTL. Set it to 60."),
        ].joined(separator: "\n")
        let excerpt = Harvester.salientExcerpt(fromJSONL: jsonl)
        #expect(excerpt.contains("USER: why is the exporter dropping rows"))
        #expect(excerpt.contains("drain interval exceeds the TTL"))
    }

    @Test func skipsMetaLinesAndKeepsLongFinalAnswerMostlyIntact() {
        let finalAnswer = "The fix: " + String(repeating: "detail ", count: 300) + "END-OF-FIX"
        let jsonl = [
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-injected>noise</system-injected>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"real question"}}"#,
            line("assistant", finalAnswer),
        ].joined(separator: "\n")
        let excerpt = Harvester.salientExcerpt(fromJSONL: jsonl)
        #expect(!excerpt.contains("system-injected"))
        #expect(excerpt.contains("real question"))
        // ~2100-char answer survives the per-entry cap far enough to keep the tail.
        #expect(excerpt.contains("END-OF-FIX"))
    }

    @Test func alsoParsesSimpleRoleContentShape() {
        // The docs describe flat {"role","content"} lines; real transcripts use the
        // envelope shape. Support both.
        let jsonl = [
            #"{"role":"user","content":"where does the vpn config live"}"#,
            #"{"role":"assistant","content":"It lives in ~/projects/vpn/config.ovpn"}"#,
        ].joined(separator: "\n")
        let excerpt = Harvester.salientExcerpt(fromJSONL: jsonl)
        #expect(excerpt.contains("vpn config live"))
        #expect(excerpt.contains("config.ovpn"))
    }
}
