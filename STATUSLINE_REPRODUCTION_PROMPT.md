# Claude Code Token Statusline — Reproduction Prompt

**How to use:** copy this entire document and paste it into any AI assistant (Claude, GPT, etc.) running on the target machine (Windows or macOS). The AI will create every file and configure Claude Code to produce the **exact** statusline below.

---

## Target output

When `node ~/.claude/scripts/token-statusline.js` runs in a 24-bit color terminal, it must print a single line equivalent to:

```
● Tokens [██████████] 444K │ ◆ CTX [████░░░░] 47% │ ▲ Burn ~30K/m │ ✦ ETA → 11:48 PM │ ◷ Reset ↺ 4h45m │ ■ Status ✗ DEAD
```

Numbers vary by session; structure, glyphs, colors, and ordering must not.

---

## Hard rules (do not deviate)

1. Create files at the **EXACT** paths listed below.
2. Use the **EXACT** file contents shown. No edits, no comments added, no "improvements," no refactoring.
3. In `settings.json` on Windows, the `command` values **must use forward slashes** (`C:/Users/...`). Backslashes get eaten by bash and the path collapses. This is non-negotiable.
4. Preserve existing keys in `settings.json`. Merge — do not overwrite the file.
5. Do not add new features (no logging, no extra glyphs, no different time format, no theme switch). Re-read this requirement if tempted.
6. Verify with the command in **§ Verification**. Do not claim success without it.

---

## Prerequisites (verify, do not install silently)

- Node.js ≥ 18 on PATH (`node --version`). If missing, stop and instruct the user to install from https://nodejs.org.
- `~/.claude/` exists (Claude Code is installed). If not, stop.

`~` resolves to:
- Windows: `C:\Users\<username>` (file paths) / `C:/Users/<username>` (settings.json command strings)
- macOS:   `/Users/<username>`

---

## File 1 — `~/.claude/token-tracker-config.json`

```json
{
  "planTokenLimit": 88000,
  "windowHours": 5,
  "contextWindowMax": 200000,
  "burnRateWindowMinutes": 15
}
```

---

## File 2 — `~/.claude/scripts/token-statusline.js`

```javascript
// Statusline: per-session token metrics with One Dark Pro colors
// Fast path  (<60s old): read state file only
// Slow path  (>=60s old): scan current session transcript, refresh state, render
'use strict';
const fs   = require('fs');
const path = require('path');
const os   = require('os');

const CLAUDE_DIR    = path.join(os.homedir(), '.claude');
const CONFIG_PATH   = path.join(CLAUDE_DIR, 'token-tracker-config.json');
const STATE_PATH    = path.join(CLAUDE_DIR, 'token-tracker-state.json');
const STATE_MAX_AGE = 60_000;

const C = {
  reset:   '\x1b[0m',
  bold:    '\x1b[1m',
  dim:     '\x1b[2m',
  green:   '\x1b[38;2;152;195;121m',
  red:     '\x1b[38;2;224;108;117m',
  yellow:  '\x1b[38;2;229;192;123m',
  blue:    '\x1b[38;2;97;175;239m',
  cyan:    '\x1b[38;2;86;182;194m',
  orange:  '\x1b[38;2;209;154;102m',
  magenta: '\x1b[38;2;198;120;221m',
  gray:    '\x1b[38;2;92;99;112m',
  dimFg:   '\x1b[38;2;130;137;151m',
  fg:      '\x1b[38;2;171;178;191m',
};
const SEP = `${C.gray} │ ${C.reset}`;

function levelColor(ratio, lowColor) {
  if (ratio >= 0.90) return C.red;
  if (ratio >= 0.75) return C.orange;
  if (ratio >= 0.50) return C.yellow;
  return lowColor;
}

function burnColor(rpm) {
  if (rpm >= 30000) return C.red;
  if (rpm >= 15000) return C.orange;
  if (rpm >=  5000) return C.yellow;
  if (rpm >      0) return C.green;
  return C.dimFg;
}

function colorBar(ratio, width, lowColor) {
  const filled = Math.round(Math.min(Math.max(ratio, 0), 1) * width);
  const color  = levelColor(ratio, lowColor);
  return `${C.gray}[${color}${'█'.repeat(filled)}${C.gray}${'░'.repeat(width - filled)}]${C.reset}`;
}

function fmtK(n) {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + 'M';
  if (n >= 1_000)     return (n / 1_000).toFixed(0) + 'K';
  return String(n);
}

function fmtTime(ms) {
  if (!isFinite(ms) || ms <= 0) return '∞';
  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor((ms % 3_600_000) / 60_000);
  return h > 0 ? `${h}h${String(m).padStart(2, '0')}m` : `${m}m`;
}

function fmtClock(ms, nowMs) {
  if (!isFinite(ms)) return '∞';
  if (ms <= 0) return 'now';
  const t   = new Date(nowMs + ms);
  const h24 = t.getHours();
  const h12 = ((h24 + 11) % 12) + 1;
  const mm  = String(t.getMinutes()).padStart(2, '0');
  const ap  = h24 < 12 ? 'AM' : 'PM';
  return `${h12}:${mm} ${ap}`;
}

let config = { planTokenLimit: 88000, windowHours: 5, contextWindowMax: 200000, burnRateWindowMinutes: 15 };
try { config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); } catch (_) {}

function scanCurrentSession(now) {
  const windowMs = config.windowHours * 60 * 60 * 1000;
  const burnMs   = config.burnRateWindowMinutes * 60 * 1000;
  const projectsDir = path.join(CLAUDE_DIR, 'projects');
  let latestMtime = 0;
  let latestPath  = null;

  function findLatest(dir, depth) {
    if (depth > 5) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return; }
    for (const e of entries) {
      const fp = path.join(dir, e.name);
      if (e.isDirectory()) { findLatest(fp, depth + 1); continue; }
      if (!e.name.endsWith('.jsonl')) continue;
      try {
        const mtime = fs.statSync(fp).mtimeMs;
        if (mtime > latestMtime) { latestMtime = mtime; latestPath = fp; }
      } catch (_) {}
    }
  }
  findLatest(projectsDir, 0);

  if (!latestPath) {
    return { sessionStart: now, windowEnd: now + windowMs, sessionTokensUsed: 0, burnRatePerMin: 0, contextWindowUsed: 0, lastUpdated: now };
  }

  let sessionTokensUsed = 0;
  let sessionStart      = null;
  let recentBilled      = 0;
  let contextWindowUsed = 0;

  let content;
  try { content = fs.readFileSync(latestPath, 'utf8'); } catch (_) { content = ''; }
  const lines = content.split('\n');

  for (const line of lines) {
    if (!line.trim()) continue;
    let e;
    try { e = JSON.parse(line); } catch (_) { continue; }
    if (e.type !== 'assistant' || !e.message || !e.message.usage) continue;
    const ts = new Date(e.timestamp).getTime();
    if (isNaN(ts)) continue;
    const u      = e.message.usage;
    const billed = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.output_tokens || 0);
    sessionTokensUsed += billed;
    if (!sessionStart || ts < sessionStart) sessionStart = ts;
    if (ts >= now - burnMs) recentBilled += billed;
  }

  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].trim()) continue;
    try {
      const e = JSON.parse(lines[i]);
      if (e.type === 'assistant' && e.message && e.message.usage) {
        const u = e.message.usage;
        contextWindowUsed = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
        break;
      }
    } catch (_) {}
  }

  const burnRatePerMin = config.burnRateWindowMinutes > 0
    ? Math.round(recentBilled / config.burnRateWindowMinutes) : 0;
  const wStart = sessionStart || now;
  const state  = { sessionStart: wStart, windowEnd: wStart + windowMs, sessionTokensUsed, burnRatePerMin, contextWindowUsed, lastUpdated: now };
  try { fs.writeFileSync(STATE_PATH, JSON.stringify(state)); } catch (_) {}
  return state;
}

const now = Date.now();
let state = null;
try { state = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch (_) {}
if (!state || (now - (state.lastUpdated || 0)) > STATE_MAX_AGE) {
  state = scanCurrentSession(now);
}

const ctxMax    = config.contextWindowMax || 200_000;
const ctxCutoff = ctxMax * 0.95;
const { sessionTokensUsed, burnRatePerMin, contextWindowUsed, windowEnd } = state;

const ctxRatio = contextWindowUsed / ctxMax;
const ctxPct   = Math.min(Math.round(ctxRatio * 100), 100);
const resetMs  = Math.max((windowEnd || now) - now, 0);
const burnStr  = burnRatePerMin > 0 ? `${fmtK(burnRatePerMin)}/m` : '--';

let etaMs  = Infinity;
let isDead = false;
if (contextWindowUsed >= ctxCutoff) {
  isDead = true;
  etaMs  = 0;
} else if (burnRatePerMin > 0) {
  const remaining = ctxCutoff - contextWindowUsed;
  etaMs  = (remaining / burnRatePerMin) * 60_000;
  isDead = etaMs < resetMs;
}
const etaStr = fmtClock(etaMs, now);

const tokenRatio    = sessionTokensUsed / ctxMax;
const tokenBarStr   = colorBar(tokenRatio, 10, C.green);
const tokenNumColor = levelColor(tokenRatio, C.green);
const tokenPart     = `${C.green}● ${C.fg}Tokens ${tokenBarStr} ${tokenNumColor}${fmtK(sessionTokensUsed)}${C.reset}`;

const ctxBarStr   = colorBar(ctxRatio, 8, C.cyan);
const ctxNumColor = levelColor(ctxRatio, C.cyan);
const ctxPart     = `${C.cyan}◆ ${C.fg}CTX ${ctxBarStr} ${ctxNumColor}${ctxPct}%${C.reset}`;

const burnPart = `${C.orange}▲ ${C.fg}Burn ${burnColor(burnRatePerMin)}~${burnStr}${C.reset}`;

const etaColor = etaMs <= 0 ? C.red : etaMs < 30 * 60_000 ? C.red : etaMs < 60 * 60_000 ? C.yellow : C.green;
const etaPart  = `${C.magenta}✦ ${C.fg}ETA ${C.magenta}→ ${etaColor}${etaStr}${C.reset}`;

const resetPart = `${C.blue}◷ ${C.fg}Reset ${C.blue}↺ ${C.blue}${fmtTime(resetMs)}${C.reset}`;

const statusPart = isDead
  ? `${C.red}■ ${C.fg}Status ${C.bold}${C.red}✗ DEAD${C.reset}`
  : `${C.green}■ ${C.fg}Status ${C.bold}${C.green}● ALIVE${C.reset}`;

process.stdout.write([tokenPart, ctxPart, burnPart, etaPart, resetPart, statusPart].join(SEP));
process.exit(0);
```

---

## File 3 — `~/.claude/scripts/update-token-state.js`

```javascript
// Stop hook: scan current session transcript and write token-tracker-state.json
'use strict';
const fs   = require('fs');
const path = require('path');
const os   = require('os');

const CLAUDE_DIR  = path.join(os.homedir(), '.claude');
const CONFIG_PATH = path.join(CLAUDE_DIR, 'token-tracker-config.json');
const STATE_PATH  = path.join(CLAUDE_DIR, 'token-tracker-state.json');
const DEBUG_PATH  = path.join(CLAUDE_DIR, 'token-tracker-debug.json');

let config = { planTokenLimit: 88000, windowHours: 5, contextWindowMax: 200000, burnRateWindowMinutes: 15 };
try { config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); } catch (_) {}

let stdinData = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => stdinData += c);
process.stdin.on('end', () => {
  const raw = stdinData.replace(/^﻿/, '');
  let hookData = {};
  try { hookData = JSON.parse(raw || '{}'); } catch (_) {}
  try { fs.writeFileSync(DEBUG_PATH, JSON.stringify({ parsed: hookData }, null, 2)); } catch (_) {}

  const now      = Date.now();
  const windowMs = config.windowHours * 60 * 60 * 1000;
  const burnMs   = config.burnRateWindowMinutes * 60 * 1000;

  let transcriptPath = hookData.transcript_path;
  if (!transcriptPath) {
    const projectsDir = path.join(CLAUDE_DIR, 'projects');
    let latestMtime = 0;
    function findLatest(dir, depth) {
      if (depth > 5) return;
      let entries;
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return; }
      for (const e of entries) {
        const fp = path.join(dir, e.name);
        if (e.isDirectory()) { findLatest(fp, depth + 1); continue; }
        if (!e.name.endsWith('.jsonl')) continue;
        try {
          const m = fs.statSync(fp).mtimeMs;
          if (m > latestMtime) { latestMtime = m; transcriptPath = fp; }
        } catch (_) {}
      }
    }
    findLatest(projectsDir, 0);
  }

  let sessionTokensUsed = 0;
  let sessionStart      = null;
  let recentBilled      = 0;
  let contextWindowUsed = 0;

  if (transcriptPath) {
    let content;
    try { content = fs.readFileSync(transcriptPath, 'utf8'); } catch (_) { content = ''; }
    const lines = content.split('\n');

    for (const line of lines) {
      if (!line.trim()) continue;
      let e;
      try { e = JSON.parse(line); } catch (_) { continue; }
      if (e.type !== 'assistant' || !e.message || !e.message.usage) continue;
      const ts = new Date(e.timestamp).getTime();
      if (isNaN(ts)) continue;
      const u      = e.message.usage;
      const billed = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.output_tokens || 0);
      sessionTokensUsed += billed;
      if (!sessionStart || ts < sessionStart) sessionStart = ts;
      if (ts >= now - burnMs) recentBilled += billed;
    }

    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].trim()) continue;
      try {
        const e = JSON.parse(lines[i]);
        if (e.type === 'assistant' && e.message && e.message.usage) {
          const u = e.message.usage;
          contextWindowUsed = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
          break;
        }
      } catch (_) {}
    }
  }

  const burnRatePerMin = config.burnRateWindowMinutes > 0
    ? Math.round(recentBilled / config.burnRateWindowMinutes) : 0;
  const wStart = sessionStart || now;
  const state  = { sessionStart: wStart, windowEnd: wStart + windowMs, sessionTokensUsed, burnRatePerMin, contextWindowUsed, lastUpdated: now };
  try { fs.writeFileSync(STATE_PATH, JSON.stringify(state)); } catch (_) {}
  process.exit(0);
});
```

---

## File 4 — `~/.claude/settings.json` (merge keys, don't overwrite)

Read existing `settings.json` (or start with `{}` if missing). Add/replace the two top-level keys below — keep every other existing key untouched.

### Windows target (forward slashes mandatory)

```json
{
  "statusLine": {
    "type": "command",
    "command": "node C:/Users/<USERNAME>/.claude/scripts/token-statusline.js"
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node C:/Users/<USERNAME>/.claude/scripts/update-token-state.js"
          }
        ]
      }
    ]
  }
}
```

### macOS target

```json
{
  "statusLine": {
    "type": "command",
    "command": "node /Users/<USERNAME>/.claude/scripts/token-statusline.js"
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node /Users/<USERNAME>/.claude/scripts/update-token-state.js"
          }
        ]
      }
    ]
  }
}
```

**If `hooks.Stop` already exists**, append the new entry to the array rather than replacing it. Filter out any prior entry whose `hooks[].command` equals the new hook command so re-running this prompt stays idempotent.

---

## Verification

After writing all four files, run:

**Windows (PowerShell):**
```powershell
node "$HOME\.claude\scripts\token-statusline.js"
```

**macOS (bash/zsh):**
```bash
node ~/.claude/scripts/token-statusline.js
```

The output must:
- Start with `●` and contain the six labels `Tokens`, `CTX`, `Burn`, `ETA`, `Reset`, `Status` separated by `│`
- End with either `● ALIVE` (green) or `✗ DEAD` (red, bold)
- Show ANSI 24-bit color escape codes if piped (e.g. `\x1b[38;2;152;195;121m`)

If any of the above fail, do not declare completion. Diagnose using **§ Failure modes** below.

---

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot find module 'C:\Users<name>.claudescripts...'` | Backslashes in `settings.json` were interpreted by bash | Switch every path in `settings.json` to forward slashes |
| `node: command not found` / not recognized | Node not installed or not on PATH | Install Node 18+; reopen terminal |
| Output prints raw escape codes (e.g. `[38;2;...m`) | Terminal lacks 24-bit color | Use Windows Terminal, iTerm2, or recent VS Code integrated terminal |
| Statusline shows zeros after fresh install | No assistant turn has completed yet | Send one message in Claude Code; next render will populate |
| Numbers from a different session show | Multiple Claude Code windows; `latestMtime` picked the other one | Self-corrects on next assistant turn in this session |

---

## What you must not do

- Do not change colors, glyphs, labels, or section ordering.
- Do not "clean up" the JavaScript or rename variables.
- Do not add console.log, telemetry, error reporting, or graceful fallbacks beyond what is shown.
- Do not introduce a CLI flag, environment variable, or "configurability" the user didn't ask for.
- Do not commit, push, install npm packages, or modify anything outside `~/.claude/`.
- Do not infer additional features from this prompt's existence ("they probably also want…"). They do not.

---

## Completion criteria

- [ ] File 1 exists and parses as valid JSON
- [ ] File 2 exists, byte-for-byte matches the source above
- [ ] File 3 exists, byte-for-byte matches the source above
- [ ] File 4 contains both `statusLine` and `hooks.Stop` entries pointing at File 2 and File 3 respectively, with forward slashes on Windows
- [ ] `node ~/.claude/scripts/token-statusline.js` prints a colored single-line statusline matching the structure in **§ Target output**
- [ ] Re-running this prompt does not duplicate entries in `hooks.Stop`

When every box checks, report:
> "Statusline installed. Restart Claude Code to see it in the bottom bar."

Stop there. Do not offer enhancements.
