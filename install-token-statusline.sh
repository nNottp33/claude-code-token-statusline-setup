#!/usr/bin/env bash
# Claude Code Token Statusline — macOS / Linux installer
# Idempotent: safe to re-run. Merges settings.json instead of overwriting.
# Usage:  bash install-token-statusline.sh

set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "Error: Node.js is required. Install Node 18+ from https://nodejs.org" >&2
  exit 1
fi

CLAUDE="$HOME/.claude"
SCRIPTS="$CLAUDE/scripts"
mkdir -p "$SCRIPTS"
echo "-> Writing files into $CLAUDE"

# ── File 1: token-tracker-config.json ────────────────────────────────────────
if [ ! -f "$CLAUDE/token-tracker-config.json" ]; then
  cat > "$CLAUDE/token-tracker-config.json" <<'JSON_EOF'
{
  "planTokenLimit": 900000,
  "windowHours": 5,
  "contextWindowMax": 200000,
  "burnRateWindowMinutes": 15
}
JSON_EOF
  echo "  Wrote token-tracker-config.json"
else
  echo "  Skipped token-tracker-config.json (already exists, keeping your settings)"
fi

# ── File 2 & 3: scripts (live rate_limits from Claude Code stdin) ────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/scripts/token-statusline.js" "$SCRIPTS/"
cp "$SCRIPT_DIR/scripts/update-token-state.js" "$SCRIPTS/"
echo "  Wrote token-statusline.js and update-token-state.js"
# ── Resolve command strings (Windows Git Bash needs Windows paths + chcp) ───
if [[ "${OSTYPE:-}" == "msys" || "${OSTYPE:-}" == "cygwin" ]]; then
  SCRIPTS_NATIVE=$(cygpath -m "$SCRIPTS")
  SETTINGS_NATIVE=$(cygpath -m "$CLAUDE/settings.json")
  STATUS_CMD="cmd /d /c \"chcp 65001 >nul & node $SCRIPTS_NATIVE/token-statusline.js\""
  HOOK_CMD="cmd /d /c \"chcp 65001 >nul & node $SCRIPTS_NATIVE/update-token-state.js\""
else
  SETTINGS_NATIVE="$CLAUDE/settings.json"
  STATUS_CMD="node $SCRIPTS/token-statusline.js"
  HOOK_CMD="node $SCRIPTS/update-token-state.js"
fi

# ── Merge settings.json via Node (idempotent, preserves existing keys) ──────
node - "$SETTINGS_NATIVE" "$STATUS_CMD" "$HOOK_CMD" <<'NODE_EOF'
const fs = require('fs');
const [,, p, sc, hc] = process.argv;
let s = {};
try { s = JSON.parse(fs.readFileSync(p, 'utf8').replace(/^﻿/, '')); } catch (_) {}
s.statusLine = { type: 'command', command: sc };
s.hooks = s.hooks || {};
s.hooks.Stop = (s.hooks.Stop || []).filter(g => !(g.hooks || []).some(h => h.command === hc));
s.hooks.Stop.push({ hooks: [{ type: 'command', command: hc }] });
fs.writeFileSync(p, JSON.stringify(s, null, 2));
console.log('settings.json merged');
NODE_EOF

# ── Warp / shell prompt integration ──────────────────────────────────────────
BASHRC="$HOME/.bashrc"
MARKER="# __claude-code-token-statusline__"
if ! grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
  {
    printf '\n%s\n' "$MARKER"
    cat <<'BASH_EOF'
__claude_tokens() {
  node "$HOME/.claude/scripts/token-statusline.js" 2>/dev/null
  echo
}
PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }__claude_tokens"
BASH_EOF
  } >> "$BASHRC"
  echo "  Appended prompt integration to $BASHRC (open a new shell to activate)"
else
  echo "  Skipped $BASHRC (already patched)"
fi

# ── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo "Preview:"
node "$SCRIPTS/token-statusline.js"
echo ""
echo ""
echo "Installed. Restart Claude Code to see the statusline."
