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
