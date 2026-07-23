#!/usr/bin/env bash
#
# Brain — one-command fresh-Mac setup.  Run it with:  make bootstrap
#
# Idempotent and safe to re-run. It:
#   1. preflights prerequisites (fails loud with the exact fix for each)
#   2. builds the `brain` CLI + Brain.app
#   3. wires Claude Code END-TO-END — the MCP server AND the SessionStart +
#      UserPromptSubmit hooks + the /brain-save skill + the CLAUDE.md recall rule
#   4. installs Brain.app to /Applications
#   5. provisions the vault (default: empty + one deletable welcome note)
#   6. builds the search index and warms Apple's on-device embedder
#   7. verifies with `brain doctor` and prints anything still needing your hands
#
# Prereqs it will NOT auto-install (it detects + instructs): full Xcode 26, the
# `claude` CLI, Node.  Extras it DOES set up: Homebrew (if missing), Obsidian,
# a `brain` symlink on PATH, and launch-at-login (the app self-registers).
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The one binary path we register + verify through (matches `make install` /
# `make doctor`, so doctor's registered-vs-running path check always agrees).
BIN="$REPO/.build/release/brain"

# --- config: extras default ON (the setup choices); override with =0 ----------
VAULT_STRATEGY="${BRAIN_SETUP_VAULT_STRATEGY:-empty}"   # empty | clone | link | embedded
DO_HOMEBREW="${BRAIN_SETUP_HOMEBREW:-1}"
DO_SYMLINK="${BRAIN_SETUP_SYMLINK:-1}"
DO_OBSIDIAN="${BRAIN_SETUP_OBSIDIAN:-1}"

NEEDS=()   # manual remainders, printed at the very end

c_blue=$'\033[1;34m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_green=$'\033[1;32m'; c_off=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# ============================================================================
# 1. PREFLIGHT — collect every failure, then print all remediations at once.
# ============================================================================
PROBLEMS=()
add() { PROBLEMS+=("$1"); }

# macOS >= 26
osver="$(sw_vers -productVersion 2>/dev/null || echo 0)"
if [ "${osver%%.*}" -lt 26 ]; then
  add "macOS 26+ required (found ${osver}). Update via System Settings -> General -> Software Update."
fi

# Full Xcode selected — actool ships ONLY in full Xcode, so this is the single
# best gate for "full Xcode present AND selected", and it must run before any
# build (a CLT-only box otherwise dies deep inside 'make icon').
if ! xcrun --find actool >/dev/null 2>&1; then
  add "Full Xcode 26 not selected (need 'actool' to compile the app icon). Currently selected: $(xcode-select -p 2>/dev/null || echo none).
       Fix: install Xcode 26 from the App Store, then:
         sudo xcode-select -s /Applications/Xcode.app
         sudo xcodebuild -license accept"
fi

# Swift >= 6.2 and Xcode license accepted (the license shows up as a swift error).
if swiftout="$(/usr/bin/swift --version 2>&1)"; then
  ver="$(printf '%s' "$swiftout" | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
  maj="${ver%%.*}"; min="${ver##*.}"
  if [ -z "$ver" ] || [ "${maj:-0}" -lt 6 ] || { [ "${maj:-0}" -eq 6 ] && [ "${min:-0}" -lt 2 ]; }; then
    add "Swift 6.2+ required (ships with Xcode 26). Found: ${ver:-unknown}."
  fi
else
  if printf '%s' "$swiftout" | grep -qi license; then
    add "Xcode license not accepted. Run: sudo xcodebuild -license accept"
  else
    add "/usr/bin/swift is not working: ${swiftout}"
  fi
fi

# claude CLI on the LOGIN-shell PATH — mirror exactly what Brain.app probes, so
# passing here can't diverge from what the Finder-launched app sees.
if ! /bin/zsh -l -c 'command -v claude' >/dev/null 2>&1; then
  add "Claude Code CLI not on your zsh login PATH — Brain.app, the MCP server, and the hooks all shell out to it.
       Install:  npm install -g @anthropic-ai/claude-code   (needs Node 18+)
       Auth:     run  claude  once and log in (Claude subscription or ANTHROPIC_API_KEY)
       Verify:   /bin/zsh -l -c 'command -v claude'"
fi

# node on the login PATH (the claude CLI runs on node; the app launches it with the login PATH).
if ! /bin/zsh -l -c 'command -v node' >/dev/null 2>&1; then
  add "Node.js 18+ not on your zsh login PATH (the claude CLI runs on node). Install: 'brew install node' or from https://nodejs.org."
fi

# network — soft warning only.
if ! curl -fsS --max-time 5 -o /dev/null https://github.com 2>/dev/null; then
  warn "network check failed — the first build fetches Swift packages from GitHub and the embedder downloads Apple's on-device model once. Get online before running."
fi

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  printf '\n%sPreflight failed — fix these, then re-run  make bootstrap:%s\n' "$c_red" "$c_off"
  for p in "${PROBLEMS[@]}"; do printf '  \xe2\x80\xa2 %s\n' "$p"; done
  exit 1
fi
say "preflight OK — macOS ${osver}, Xcode toolchain, claude + node all present"

# ============================================================================
# 2. HOMEBREW (opted-in) — install if missing; used for the Obsidian cask.
# ============================================================================
brew_bin=""
if command -v brew >/dev/null 2>&1; then brew_bin="$(command -v brew)"
elif [ -x /opt/homebrew/bin/brew ]; then brew_bin=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then brew_bin=/usr/local/bin/brew
fi
if [ -z "$brew_bin" ] && [ "$DO_HOMEBREW" = 1 ]; then
  say "installing Homebrew (used to install Obsidian)…"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || warn "Homebrew install failed — skipping brew-based extras."
  [ -x /opt/homebrew/bin/brew ] && brew_bin=/opt/homebrew/bin/brew
  [ -z "$brew_bin" ] && [ -x /usr/local/bin/brew ] && brew_bin=/usr/local/bin/brew
fi
[ -n "$brew_bin" ] && eval "$("$brew_bin" shellenv)" || true

# ============================================================================
# 3. BUILD (compile release once) + optional convenience symlink.
# ============================================================================
say "building the brain CLI + Brain.app (first build fetches Swift packages)…"
make release || die "build failed — see the errors above."

if [ "$DO_SYMLINK" = 1 ]; then
  say "symlinking 'brain' -> /usr/local/bin (convenience; needs sudo)…"
  if sudo mkdir -p /usr/local/bin && sudo ln -sf "$BIN" /usr/local/bin/brain; then
    :
  else
    warn "couldn't create /usr/local/bin/brain (sudo declined?) — invoke the CLI as $BIN."
    NEEDS+=("'brain' isn't on your PATH; run it as $BIN, or add the symlink later.")
  fi
fi

# ============================================================================
# 4. WIRE CLAUDE CODE END-TO-END — MCP server + both hooks + skill + recall rule.
#    A single idempotent `brain install` sets up ALL of it; nothing manual.
# ============================================================================
say "wiring Claude Code: MCP server + SessionStart & UserPromptSubmit hooks + /brain-save skill + recall rule…"
"$BIN" install
say "  wired: mcpServers.brain, SessionStart (brain brief), UserPromptSubmit (brain search --hook), /brain-save skill, CLAUDE.md recall rule"

# ============================================================================
# 5. INSTALL Brain.app -> /Applications  (non-fatal: the wiring above is done).
# ============================================================================
say "assembling + installing Brain.app -> /Applications…"
make install-app \
  || { warn "Brain.app build/install failed — the CLI + Claude Code wiring are already done."; \
       NEEDS+=("Re-run 'make install-app' to finish installing the GUI app."); }

# ============================================================================
# 6. PROVISION THE VAULT, then reindex (also warms the on-device embedder).
# ============================================================================
provision_vault() {
  local vault; vault="${BRAIN_VAULT:-$HOME/BrainVault}"
  case "$VAULT_STRATEGY" in
    clone)
      [ -n "${BRAIN_VAULT_REPO:-}" ] || die "clone strategy needs BRAIN_VAULT_REPO=<git-url>"
      if [ -d "$vault/.git" ]; then
        say "vault repo present -> git pull"; git -C "$vault" pull --ff-only || warn "git pull failed; using the local copy"
      elif [ -e "$vault" ] && [ -n "$(ls -A "$vault" 2>/dev/null)" ]; then
        die "$vault exists and isn't the expected vault git repo — move it aside first"
      else
        say "cloning vault -> $vault"; git clone "$BRAIN_VAULT_REPO" "$vault"
      fi ;;
    link)
      [ -d "$vault" ] || die "link strategy: BRAIN_VAULT=$vault doesn't exist yet (let the sync client finish first)" ;;
    embedded)
      vault="$REPO/vault"; [ -d "$vault" ] || die "embedded strategy: no 'vault/' dir committed in the repo" ;;
    empty|*)
      say "using an empty vault at $vault" ;;
  esac

  mkdir -p "$vault"
  export BRAIN_VAULT="$vault"
  if [ "$vault" != "$HOME/BrainVault" ]; then
    NEEDS+=("Vault is at a non-default path. Finder-launched Brain.app only reads ~/BrainVault unless you persist it: launchctl setenv BRAIN_VAULT '$vault' (plus a LaunchAgent to survive reboot).")
  fi

  # Empty-start polish: seed ONE deletable welcome note so search + `brain doctor`
  # are green immediately and the embedder warms on real content.
  if ! ls "$vault"/*.md >/dev/null 2>&1; then
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
      printf '%s\n' '---' 'id: 1' 'title: "Welcome to your brain"' 'type: how-it-works' \
        'status: active' 'source: manual' "created: $now" "updated: $now" '---' ''
      cat <<'BODY'
This is your first note — delete it anytime.

Your brain lives here as plain Markdown (one file per note); the SQLite database
and embeddings are a rebuildable index over these files (`brain reindex`). Claude
reads and writes notes through the **brain** MCP server, injects relevant ones into
every Claude Code session (the SessionStart + UserPromptSubmit hooks), and saves new
ones when you run `/brain-save`. Ask anything with ⌥Space.
BODY
    } > "$vault/1-welcome-to-your-brain.md"
    say "seeded a starter note at $vault/1-welcome-to-your-brain.md (delete it anytime)"
  fi

  say "building the search index + warming the on-device embedder (first run downloads Apple's model once)…"
  if ! "$BIN" reindex; then
    warn "reindex failed (usually offline: the embedder asset can't download). Falling back to a keyword-only index."
    "$BIN" reindex --keyword-only || warn "keyword-only reindex also failed — check the vault path."
    NEEDS+=("Re-run 'brain reindex' once you're online to enable semantic (embedding) search.")
  fi
}
provision_vault

# ============================================================================
# 7. OBSIDIAN (opted-in) — install + open on the vault for editing.
# ============================================================================
if [ "$DO_OBSIDIAN" = 1 ]; then
  if ! [ -d /Applications/Obsidian.app ] && [ -n "$brew_bin" ]; then
    say "installing Obsidian…"; "$brew_bin" install --cask obsidian || warn "Obsidian install failed (skipping)."
  fi
  if [ -d /Applications/Obsidian.app ]; then
    open -a Obsidian "$BRAIN_VAULT" 2>/dev/null || true
  else
    NEEDS+=("Install Obsidian (https://obsidian.md), then 'Open folder as vault' -> $BRAIN_VAULT to edit notes.")
  fi
fi

# ============================================================================
# 8. FIRST LAUNCH — registers ⌥Space; the app self-registers as a login item.
# ============================================================================
if [ -d /Applications/Brain.app ]; then
  say "launching Brain.app (registers the ⌥Space hotkey and, once, the login item)…"
  open /Applications/Brain.app || warn "couldn't launch Brain.app"
else
  warn "Brain.app isn't installed — skipping launch."
fi

# ============================================================================
# 9. VERIFY + SUMMARY.
# ============================================================================
say "verifying (brain doctor)…"
docout="$("$BIN" doctor 2>&1)" || true
printf '%s\n' "$docout"

# A fresh/empty vault (or a pending embedder download) legitimately fails the
# 'vault' and 'embeddings current' checks. Any OTHER failing (✗) line is real.
realbad="$(printf '%s\n' "$docout" | grep '^✗' | grep -Ev 'vault|embeddings current' || true)"
if [ -n "$realbad" ]; then
  warn "brain doctor flagged issues that are NOT the expected empty-vault case:"
  printf '%s\n' "$realbad" | while IFS= read -r l; do printf '       %s\n' "$l"; done
  NEEDS+=("Resolve the brain doctor ✗ lines above, then re-check with 'make doctor'.")
fi

NEEDS+=("If you haven't yet, run 'claude' once to authenticate Claude Code — the ⌥Space panel and hooks use it.")

printf '\n%s====================================================================%s\n' "$c_green" "$c_off"
printf '  Brain bootstrap complete\n'
printf '  built brain CLI + Brain.app; wired Claude Code (MCP + both hooks + skill + recall rule)\n'
printf '  search index built; on-device embedder warmed\n'
printf '  /Applications/Brain.app installed and launched  —  press ⌥Space to ask\n'
if [ "${#NEEDS[@]}" -gt 0 ]; then
  printf '\n  still needs your hands:\n'
  for n in "${NEEDS[@]}"; do printf '     \xe2\x80\xa2 %s\n' "$n"; done
fi
printf '%s====================================================================%s\n' "$c_green" "$c_off"
