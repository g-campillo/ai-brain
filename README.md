# Brain

A persistent, searchable knowledge base for Claude Code. Claude automatically
recalls past fixes, project context, and how-things-work notes — and harvests
new learnings from finished sessions, entirely on-device.

## How it works

- **Source of truth**: SQLite at `~/Library/Application Support/Brain/brain.db`
  (WAL — app, MCP server, and hook processes share it safely).
- **Search**: hybrid — FTS5 keyword (BM25) + semantic vectors from Apple's
  on-device `NLContextualEmbedding` (no API, no cost), fused with weighted RRF.
  ~50ms at 10k notes.
- **MCP server** (`brain mcp`): `brain_search`, `brain_get`, `brain_save`,
  `brain_recent` — Claude's deliberate access.
- **Hooks** (the automatic part):
  - `SessionStart` → injects the `project-context` notes for the cwd.
  - `UserPromptSubmit` → ~0.3s hybrid search of every prompt; injects notes
    that pass a confidence gate (full keyword match, or similarity z-score ≥ 1.5
    against the query's own corpus distribution). Deduped per session.
  - `Stop` → distills durable learnings from the transcript into `inbox` notes
    using the on-device Foundation Models LLM (requires Apple Intelligence
    enabled). Throttled; runs async; never blocks the session.
- **Brain.app**: browse/edit notes, review the harvest Inbox
  (promote/discard), and a Search Playground showing exactly what the hooks
  would inject and why (rrf/sim/z scores).

## Setup (any Mac)

```sh
git clone <this repo> && cd ai-brain
make install        # builds release + registers MCP server & hooks in ~/.claude
make app && open Brain.app   # optional UI
```

Requirements: Xcode 26+ (build uses `/usr/bin/swift` — the Foundation Models
`@Generable` macro is not in swift.org toolchains). For session harvesting,
enable **System Settings → Apple Intelligence & Siri**.

## Commands

```sh
brain search -q "publish hangs" [-k 5] [--keyword-only]
brain brief --cwd ~/projects/etk-sandbox   # what SessionStart injects
brain index [--rebuild]                    # re-embed missing/stale notes
brain export [--out DIR]                   # dump all notes as markdown
brain install [--home DIR]                 # idempotent hook/MCP registration
```

Hook activity logs to `~/Library/Logs/brain.log`.

## Development

`make test` (21 tests, includes a 10k-note latency benchmark asserting
p95 < 100ms). Multi-computer sync is deliberately deferred — `brain export`
keeps the data portable in the meantime.
