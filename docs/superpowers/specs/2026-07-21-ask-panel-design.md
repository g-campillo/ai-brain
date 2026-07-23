# ⌥Space "Ask Your Brain" panel — design

## Context

Brain.app can only *search* the brain (menu-bar hit list); getting a synthesized answer requires opening Claude Code manually. This feature adds a Raycast/Spotlight-style flow: press **⌥Space** anywhere → floating input panel → type a question → the `claude` CLI (headless) agentically searches the brain via the already-registered brain MCP server → the panel streams a formatted answer, with follow-up questions continuing the same Claude session.

**Decisions:**
- Answer engine: `claude` CLI headless (`claude -p`) — reuses Claude Code auth + the brain MCP server `brain install` already registered user-globally in `~/.claude.json`. Not the Anthropic API, not FoundationModels.
- Model picker in the panel (Fable 5 / Opus 4.8 / Sonnet 5 / Haiku 4.5 → CLI aliases `fable/opus/sonnet/haiku`); **last-used model persists as the default** (`@AppStorage("askModel")`, default `"sonnet"`).
- Hotkey: **⌥Space chord** via Carbon `RegisterEventHotKey` — no Accessibility permission, no new dependency, survives ad-hoc re-signing (chosen over double-tap Option).
- **Follow-up thread**: input stays active after an answer; follow-ups `--resume <session_id>`. Closing the panel (Esc / ⌥Space / click-away) ends the thread; next summon is fresh.

Verified up front: claude CLI v2.1.216 supports `--include-partial-messages`, `--tools ""`, model aliases incl. `fable`; `~/.claude.json` has `mcpServers.brain` (absolute path, user scope) so headless runs inherit it; new files under `Sources/BrainApp/` are auto-globbed — no Package.swift / Makefile / Info.plist changes.

## Components

| File | Responsibility |
|---|---|
| `Sources/BrainApp/AppDelegate.swift` | Carbon ⌥Space registration (capture-free C callback → `MainActor.assumeIsolated`) |
| `Sources/BrainApp/AskPanelController.swift` | `AskPanel` (NSPanel: `canBecomeKey`, `cancelOperation`→hide) + singleton controller: show/hide/toggle, mouse-screen placement, two-state height (64/520, top edge fixed), resign-key dismiss |
| `Sources/BrainApp/AskSession.swift` | claude subprocess + stream-json parsing + transcript state |
| `Sources/BrainApp/AskView.swift` | SwiftUI: input + model picker + streaming markdown transcript |
| `Sources/BrainApp/BrainApp.swift` | `@NSApplicationDelegateAdaptor` line |
| `Sources/BrainApp/MenuBarView.swift` | "Ask Claude ⌥Space" fallback button |

## Key mechanics

**Panel**: `styleMask [.borderless, .nonactivatingPanel]` — becomes key *without activating the app* (frontmost app keeps its menu bar). `level .floating`, joins all spaces + fullscreen aux, clear background (SwiftUI draws Liquid Glass — `.glassEffect(.regular)` rounded 28, content clipped to the same shape), `hasShadow = false` — the glass backdrop writes alpha across the whole rect, so AppKit would cast a rectangular shadow that shows as square plates through the corner cutouts (NSGlassEffectView was tried instead: doesn't round its corners or size its contentView), `hidesOnDeactivate = false` (NSPanel defaults true). Fresh `AskSession` + fresh `NSHostingView` per summon — clean thread per spec, reliable `@FocusState` seeding via `.onAppear`.

**claude invocation** (`AskSession.ask`): binary + PATH resolved once per launch via `/bin/zsh -l -c` (Finder PATH is bare); prompt via stdin (then close stdin — claude hangs otherwise); args:

```
-p --output-format stream-json --include-partial-messages --verbose
--model <alias> [--resume <sessionId>]
--tools ""            (no built-ins; MCP tools unaffected)
--allowedTools mcp__brain__brain_search,mcp__brain__brain_get,mcp__brain__brain_recent,mcp__brain__brain_overview
--append-system-prompt <answer-from-brain, cite [id · title], lists/code fences ok>
--max-turns 16
```

Read-only brain tools only — the palette can never write notes.

**Streaming**: `FileHandle.bytes.lines` in MainActor-inherited Tasks (stderr drained concurrently to a 2000-char tail — prevents pipe-full deadlock). Tolerant per-line decode: every event's `session_id` stored (latest wins — resume forks), `stream_event` text deltas append live, `tool_use` → "Searching brain…" status, `result` replaces accumulated text (authoritative final answer) or surfaces `is_error`. Process death without `result` → stderr tail as error.

**Rendering**: block-level markdown via `MarkdownBlocks.swift` (`MarkdownText`): `AttributedString(markdown:, .full)` split into blocks by `PresentationIntent` identity — paragraphs, headings, fenced code (fill-backed, wraps), bullet/ordered lists, block quotes; inline styling rides along as `inlinePresentationIntent`. Transcript is a Q&A document flow (tinted `arrow.turn.down.right` question rows, full-width answers, 14pt exchange gap), not chat bubbles. Streaming re-parses per delta (few KB, sub-ms); an unterminated fence is valid CommonMark so partial code renders as a growing block. Simplifications: tables → paragraphs, nested lists lose indentation. `NoteDetailView` still uses the old inline-only helper — `MarkdownText` can replace it later.

**GUI-test hook**: launching with `BRAIN_ASK_TEST=1` summons the panel and seeds a canned markdown-rich transcript (`AskSession.seedCannedTranscript`) — visual verification without synthetic ⌥Space (Chrome reacts to it) or fake typing.

## Edge cases

claude missing → error row · auth failure → `is_error`/stderr shown · MCP unregistered → toolless answer, no crash · dismiss mid-stream → SIGTERM · new ask cancels in-flight run · hotkey conflict → logged, menu-bar fallback · ⌥Space stops typing a non-breaking space while Brain runs (inherent) · first token slow because the user's own brain hooks fire per headless session (and usefully inject recall).
