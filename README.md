# Brain

A persistent, searchable knowledge base for Claude Code. Claude automatically
recalls past fixes, project context, and how-things-work notes — and saves a
rich summary of any session worth keeping when you run `/brain-save`.

## How it works

- **Source of truth**: an Obsidian vault of Markdown files at `~/BrainVault`
  (`$BRAIN_VAULT` to override). The SQLite database at
  `~/Library/Application Support/Brain/brain.db` is a rebuildable index over it
  (`brain reindex`) — a shared WAL across the app, MCP server, and hook processes.
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
- **Brain.app**: a menu-bar app with an **⌥Space Ask panel** — a floating,
  Spotlight-style bar that sends your question to Claude, searches the brain over
  MCP, and streams back a cited answer. Also opens the vault folder and toggles
  launch-at-login.

## Setup (any Mac)

One command does the whole thing — preflight, build, wire Claude Code, install
the app, provision the vault, and verify:

```sh
git clone <this repo> && cd ai-brain
make bootstrap
```

`make bootstrap` (see `scripts/setup.sh`) is idempotent and safe to re-run. It
**wires Claude Code end-to-end** — the `brain` MCP server *and* the `SessionStart`
+ `UserPromptSubmit` hooks *and* the `/brain-save` skill *and* the `~/.claude/CLAUDE.md`
recall rule — then builds & installs Brain.app, seeds an empty vault, warms the
on-device embedder, and runs `brain doctor`. Prerequisites it can't provide, it
detects and prints an exact fix for (it never force-installs them).

**Prerequisites** (bootstrap checks each and tells you how to fix it):
- **macOS 26+**
- **Full Xcode 26** installed and selected (`xcode-select -p` → an `Xcode.app`,
  not the Command Line Tools) with its license accepted — needed for
  `/usr/bin/swift` and `actool`.
- **Node 18+ and Claude Code**, authenticated:
  `npm i -g @anthropic-ai/claude-code`, then run `claude` once to log in.
- ~100 MB of network on the first run (Swift packages + a one-time embedder asset).

**Where your notes live** — bootstrap defaults to a fresh empty vault; override
with `BRAIN_SETUP_VAULT_STRATEGY`:
- `empty` (default) — start fresh; a deletable welcome note is seeded.
- `clone` — `BRAIN_VAULT_REPO=<git-url>` clones your vault (future syncs are `git pull`/`push`).
- `link` — `BRAIN_VAULT=/path/to/synced/folder` points at an existing iCloud/Obsidian-Sync vault.
- `embedded` — a `vault/` directory committed inside this repo.

**How your notes travel to a new Mac** — the Markdown vault is the source of
truth; the SQLite index + embeddings are fully rebuildable. So moving machines =
*bring the vault* (git clone / iCloud / copy the folder) → `make bootstrap` →
`brain reindex` rebuilds the database and re-embeds. You never copy `brain.db`;
the embedder asset re-downloads once. If your vault isn't at the default
`~/BrainVault`, persist `BRAIN_VAULT` for the GUI app
(`launchctl setenv BRAIN_VAULT <path>` + a LaunchAgent).

Prefer the old manual steps? `make install` wires Claude Code only;
`make install-app` builds and installs Brain.app.

## Commands

```sh
make bootstrap                             # one-command fresh-Mac setup (see above)
make doctor                                # verify wiring + DB + embedder
make reindex                               # rebuild the index from the vault

brain search -q "publish hangs" [-k 5] [--keyword-only]
brain reindex [--keyword-only]             # rebuild the search index from the vault
brain brief --cwd ~/projects/etk-sandbox   # what SessionStart injects
brain index [--rebuild]                    # re-embed missing/stale notes
brain export [--out DIR]                   # dump all notes as markdown
brain install [--home DIR]                 # idempotent registration (MCP, hooks, skill, rule)
brain overview                             # totals, breakdowns, coverage, recent notes
brain doctor [--home DIR]                  # verify wiring + DB + embedder; nonzero exit on failure
```

Hook activity logs to `~/Library/Logs/brain.log`. If you added the `brain`
symlink, run health checks via `make doctor` — a bare `brain doctor` typed
through the symlink shows a harmless path-mismatch on the MCP-registration check.

## Development

`make test` (includes a 10k-note latency benchmark asserting p95 < 100ms).
Multi-computer sync piggybacks on the Markdown vault: keep `~/BrainVault` in git
or iCloud/Obsidian Sync, and `brain reindex` rebuilds the index on any Mac.
