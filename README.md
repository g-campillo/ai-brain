# Brain

A persistent, searchable knowledge base for Claude Code. Claude automatically
recalls past fixes, project context, and how-things-work notes — and saves a
rich summary of any session worth keeping when you run `/brain-save`.

## How it works

- **Source of truth**: SQLite at `~/Library/Application Support/Brain/brain.db`
  (WAL — app, MCP server, and hook processes share it safely).
- **Search**: hybrid — FTS5 keyword (BM25) + semantic vectors from Apple's
  on-device `NLContextualEmbedding` (no API, no cost), fused with weighted RRF.
  ~50ms at 10k notes.
- **MCP server** (`brain mcp`): `brain_search`, `brain_get`, `brain_save`,
  `brain_update` (patch/append/archive — keeps notes from going stale),
  `brain_recent`, `brain_overview` (what does the brain cover?) — Claude's
  deliberate access.
- **Hooks** (the automatic part):
  - `SessionStart` → injects the `project-context` notes for the cwd.
  - `UserPromptSubmit` → ~0.3s hybrid search of every prompt; injects notes
    that pass a confidence gate (full keyword match, or similarity z-score ≥ 1.5
    against the query's own corpus distribution). Deduped per session.
- **Saving** (the intentional part): run `/brain-save` at the end of a session
  worth keeping — Claude writes one structured `session-summary` note (goal,
  what/how, root cause, gotchas, verification) and saves it. Live immediately,
  no approval step; throwaway sessions just never run it. A managed block in
  `~/.claude/CLAUDE.md` also tells Claude to `brain_search` across all projects
  before starting related work.
- **Brain.app**: browse/edit notes, a Search Playground showing exactly what
  the hooks would inject and why (rrf/sim/z scores), and a Recall tab logging
  every real recall decision (injected or gated out, last 500).

## Setup (any Mac)

```sh
git clone <this repo> && cd ai-brain
make install        # builds release + registers MCP, hooks, /brain-save skill, recall rule
make app && open Brain.app   # optional UI
```

Requirements: Xcode 26+ (build uses `/usr/bin/swift`).

## Commands

```sh
brain search -q "publish hangs" [-k 5] [--keyword-only]
brain brief --cwd ~/projects/etk-sandbox   # what SessionStart injects
brain index [--rebuild]                    # re-embed missing/stale notes
brain export [--out DIR]                   # dump all notes as markdown
brain install [--home DIR]                 # idempotent registration (MCP, hooks, skill, rule)
brain overview                             # totals, breakdowns, coverage, recent notes
brain doctor [--home DIR]                  # verify wiring + DB + embedder; nonzero exit on failure
```

Hook activity logs to `~/Library/Logs/brain.log`.

## Development

`make test` (includes a 10k-note latency benchmark asserting p95 < 100ms).
Multi-computer sync is deliberately deferred — `brain export` keeps the data
portable in the meantime.
