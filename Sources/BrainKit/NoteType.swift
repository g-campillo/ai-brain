/// The content taxonomy. Each case is a kind of knowledge the brain stores.
public enum NoteType: String, CaseIterable, Codable, Sendable {
    case troubleshooting   // "saw error X on site Y, root cause Z, fixed by..."
    case howItWorks = "how-it-works"
    case projectContext = "project-context"  // keyed to a directory; auto-injected at session start
    case runbook
    case environment       // site/env registry: URLs, versions, quirks, where creds live
    case decision
    case glossary
    case learning          // feedback on how Claude should behave
    case snippet
    case contact           // who owns what / escalation paths
    case ticketOutcome = "ticket-outcome"
    case sessionSummary = "session-summary"  // one /brain-save note per kept session
}
