# Claude Code Token Statusline (One Dark Pro)

Self-contained setup guide. Following this end-to-end on any machine reproduces the same colored token-usage statusline shown below, with no deviation.

```
● Tokens [██████░░░░] 12K/88K left │ ■ Status ● ALIVE │ ▲ Burn ~5K/m │ ◆ Usage Limit [████░░░░] 45% (7d:12%) │ ✦ ETA → 11:48 PM │ ◷ Reset ↺ 4h45m
```

Each section has a signature color (green / red-green / orange / cyan / magenta / blue). Values adapt by severity level: green → yellow → orange → red.

---

## Prerequisites

- **Node.js 18+** on `PATH` (verify: `node --version`)
- **Claude Code** installed, with `~/.claude/` directory present
- Terminal that supports 24-bit ANSI color (Windows Terminal / iTerm2 / modern VS Code terminal — all fine)

`~` means:
- Windows: `C:\Users\<your-username>`
- macOS: `/Users/<your-username>`
- Linux: `/home/<your-username>`

---

## File layout

After install, you will have these four files (path style differs per OS — see "Path gotcha" below):

```
~/.claude/
├── settings.json                          ← merged with existing
├── token-tracker-config.json              ← new
└── scripts/
    ├── token-statusline.js                ← new
    └── update-token-state.js              ← new
```

---

## Path gotcha (Windows only — read this first)

In `settings.json`, **always use forward slashes** in the command paths:

```
✅  "node C:/Users/<you>/.claude/scripts/token-statusline.js"
❌  "node C:\\Users\\<you>\\.claude\\scripts\\token-statusline.js"
```

Claude Code routes hook / statusline commands through **bash** on Windows, which interprets `\U`, `\.`, `\s`, `\u` as escape sequences and silently strips the backslashes — the path collapses to `C:\Users<you>.claudescripts...` and Node throws `Cannot find module`. Forward slashes bypass that entirely; Node accepts them natively on Windows.

---

## File 1 — `~/.claude/token-tracker-config.json`

```json
{
  "planTokenLimit": 900000,
  "windowHours": 5,
  "contextWindowMax": 200000,
  "burnRateWindowMinutes": 15
}
```

**Knobs:**
- `windowHours` — length of the session reset window (Claude Code plan reset is 5h)
- `contextWindowMax` — model context size; 200K covers Sonnet/Opus 4.x
- `burnRateWindowMinutes` — sliding window for computing tokens/min
- `planTokenLimit` — output-token budget estimate for the 5h window (used as fallback when API data is unavailable)

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

// ── One Dark Pro palette ──────────────────────────────────────────────────────
const C = {
  reset:   '\x1b[0m',
  bold:    '\x1b[1m',
  dim:     '\x1b[2m',
  green:   '\x1b[38;2;152;195;121m',   // #98c379
  red:     '\x1b[38;2;224;108;117m',   // #e06c75
  yellow:  '\x1b[38;2;229;192;123m',   // #e5c07b
  blue:    '\x1b[38;2;97;175;239m',    // #61afef
  cyan:    '\x1b[38;2;86;182;194m',    // #56b6c2
  orange:  '\x1b[38;2;209;154;102m',   // #d19a66
  magenta: '\x1b[38;2;198;120;221m',   // #c678dd
  gray:    '\x1b[38;2;92;99;112m',     // #5c6370  — separators / brackets
  dimFg:   '\x1b[38;2;130;137;151m',   // muted label
  fg:      '\x1b[38;2;171;178;191m',   // #abb2bf  — bright text
};
const SEP = `${C.gray} │ ${C.reset}`;

// ── helpers ───────────────────────────────────────────────────────────────────

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

// ── config ────────────────────────────────────────────────────────────────────

let config = { planTokenLimit: 88000, windowHours: 5, contextWindowMax: 200000, burnRateWindowMinutes: 15 };
try { config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); } catch (_) {}

// ── per-session scanner ───────────────────────────────────────────────────────

function scanCurrentSession(now) {
  const windowMs     = config.windowHours * 60 * 60 * 1000;
  const burnMs       = config.burnRateWindowMinutes * 60 * 1000;

  // Find the most recently modified transcript across all projects
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

  // Forward pass: sum billed tokens & find session start
  for (const line of lines) {
    if (!line.trim()) continue;
    let e;
    try { e = JSON.parse(line); } catch (_) { continue; }
    if (e.type !== 'assistant' || !e.message || !e.message.usage) continue;

    const ts = new Date(e.timestamp).getTime();
    if (isNaN(ts)) continue;

    const u      = e.message.usage;
    // Count only output tokens within the rolling window — input tokens grow
    // quadratically with context and don't reflect usage limit consumption
    const billed = u.output_tokens || 0;
    if (ts >= now - windowMs) sessionTokensUsed += billed;
    if (!sessionStart || ts < sessionStart) sessionStart = ts;
    if (ts >= now - burnMs) recentBilled += billed;
  }

  // Backward pass: get latest context window size
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

  // Preserve API-sourced fields from existing state (only Stop hook can refresh them)
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch (_) {}

  const wStart = sessionStart || now;
  const state  = {
    sessionStart:      wStart,
    windowEnd:         wStart + windowMs,
    sessionTokensUsed,
    burnRatePerMin,
    contextWindowUsed,
    lastUpdated:       now,
    usageLimitPct:           prev.usageLimitPct,
    usageLimitResetsAt:      prev.usageLimitResetsAt,
    usageLimitFetchedAt:     prev.usageLimitFetchedAt,
    usageLimitSevenDayPct:   prev.usageLimitSevenDayPct,
    usageLimitPrevPct:       prev.usageLimitPrevPct,
    usageLimitPrevFetchedAt: prev.usageLimitPrevFetchedAt,
  };
  try { fs.writeFileSync(STATE_PATH, JSON.stringify(state)); } catch (_) {}
  return state;
}

// ── load or refresh state ─────────────────────────────────────────────────────

const now = Date.now();
let state = null;
try { state = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch (_) {}
if (!state || (now - (state.lastUpdated || 0)) > STATE_MAX_AGE) {
  state = scanCurrentSession(now);
}

// ── compute display metrics ───────────────────────────────────────────────────

const planLimit  = config.planTokenLimit || 900_000;
const {
  sessionTokensUsed, burnRatePerMin, contextWindowUsed, windowEnd,
  usageLimitPct, usageLimitResetsAt, usageLimitFetchedAt,
  usageLimitPrevPct, usageLimitPrevFetchedAt,
} = state;

// Prefer live API data; fall back to local output-token estimate.
const hasLive   = typeof usageLimitPct === 'number';
const planPct   = hasLive
  ? Math.min(Math.round(usageLimitPct), 100)
  : Math.min(Math.round((sessionTokensUsed / planLimit) * 100), 100);
const planRatio = planPct / 100;

// Reset countdown: prefer API's resets_at, fall back to local windowEnd.
const resetMs = hasLive && usageLimitResetsAt
  ? Math.max(usageLimitResetsAt - now, 0)
  : Math.max((windowEnd || now) - now, 0);

const burnStr = burnRatePerMin > 0 ? `${fmtK(burnRatePerMin)}/m` : '--';

// ETA: when usage will hit 95%.
// With live data: extrapolate from observed %-delta between readings.
// Without: extrapolate from local tokens-per-min vs planLimit cutoff.
let etaMs  = Infinity;
let isDead = false;
// A DEAD verdict from rate extrapolation is only trustworthy once usage is
// meaningful; below this a 2-sample %-delta over a short interval over-reacts
// to one turn's burst and falsely flags DEAD with hours of runway left.
const DEAD_MIN_PCT = 50;

if (planPct >= 95) {
  isDead = true;
  etaMs  = 0;
} else if (hasLive && typeof usageLimitPrevPct === 'number' && usageLimitPrevFetchedAt) {
  const dPct = usageLimitPct - usageLimitPrevPct;
  const dMin = (usageLimitFetchedAt - usageLimitPrevFetchedAt) / 60_000;
  const pctPerMin = dMin > 0 ? dPct / dMin : 0;
  if (pctPerMin > 0) {
    etaMs  = ((95 - usageLimitPct) / pctPerMin) * 60_000;
    isDead = etaMs < resetMs && planPct >= DEAD_MIN_PCT;
  }
} else if (!hasLive && burnRatePerMin > 0) {
  const cutoff    = planLimit * 0.95;
  const remaining = cutoff - sessionTokensUsed;
  etaMs  = (remaining / burnRatePerMin) * 60_000;
  isDead = etaMs < resetMs && planPct >= DEAD_MIN_PCT;
}

const etaStr = fmtClock(etaMs, now);

// ── compose colored output ────────────────────────────────────────────────────

// Session token section — signature: green
// Used = this session's output tokens. Remaining = budget left before dead (95% of 5h limit).
const remainingPct    = Math.max(0, 95 - planPct);
const remainingTokens = Math.round((remainingPct / 100) * planLimit);
const tokenRatio      = sessionTokensUsed / Math.max(sessionTokensUsed + remainingTokens, 1);
const tokenBarStr     = colorBar(tokenRatio, 10, C.green);
const tokenNumColor   = levelColor(tokenRatio, C.green);
const tokenPart       = `${C.green}● ${C.fg}Tokens ${tokenBarStr} ${tokenNumColor}${fmtK(sessionTokensUsed)}${C.dimFg}/${C.green}${fmtK(remainingTokens)}${C.dimFg} left${C.reset}`;

// Usage limit section — signature: cyan
const planBarStr   = colorBar(planRatio, 8, C.cyan);
const planNumColor = levelColor(planRatio, C.cyan);
const usageDetail  = hasLive
  ? (typeof state.usageLimitSevenDayPct === 'number' ? `${C.dimFg}(7d:${Math.round(state.usageLimitSevenDayPct)}%)` : '')
  : `${C.dimFg}(local ~${fmtK(sessionTokensUsed)}/${fmtK(planLimit)})`;
const ctxPart      = `${C.cyan}◆ ${C.fg}Usage Limit ${planBarStr} ${planNumColor}${planPct}% ${usageDetail}${C.reset}`;

// Burn rate — signature: orange
const burnPart = `${C.orange}▲ ${C.fg}Burn ${burnColor(burnRatePerMin)}~${burnStr}${C.reset}`;

// ETA — signature: magenta
const etaColor = etaMs <= 0 ? C.red : etaMs < 30 * 60_000 ? C.red : etaMs < 60 * 60_000 ? C.yellow : C.green;
const etaPart  = `${C.magenta}✦ ${C.fg}ETA ${C.magenta}→ ${etaColor}${etaStr}${C.reset}`;

// Reset countdown — signature: blue
const resetPart = `${C.blue}◷ ${C.fg}Reset ${C.blue}↺ ${C.blue}${fmtTime(resetMs)}${C.reset}`;

// Status chip — bicolor (red/green)
const statusPart = isDead
  ? `${C.red}■ ${C.fg}Status ${C.bold}${C.red}✗ DEAD${C.reset}`
  : `${C.green}■ ${C.fg}Status ${C.bold}${C.green}● ALIVE${C.reset}`;

// Responsive: pack segments onto as many lines as the terminal width needs.
// Claude Code passes COLUMNS (so do interactive shells); fall back to 80.
const cols   = (() => { const c = parseInt(process.env.COLUMNS, 10); return Number.isFinite(c) && c > 0 ? c : 80; })();
const visLen = s => [...s.replace(/\x1b\[[0-9;]*m/g, '')].length;
const sepLen = visLen(SEP);
const parts  = [tokenPart, statusPart, burnPart, ctxPart, etaPart, resetPart];
const lines  = [];
let cur = '', curLen = 0;
for (const p of parts) {
  const pLen = visLen(p);
  if (cur === '') { cur = p; curLen = pLen; }
  else if (curLen + sepLen + pLen <= cols) { cur += SEP + p; curLen += sepLen + pLen; }
  else { lines.push(cur); cur = p; curLen = pLen; }
}
if (cur !== '') lines.push(cur);
process.stdout.write(lines.join('\n'));
process.exit(0);
```

---

## File 3 — `~/.claude/scripts/update-token-state.js`

```javascript
// Stop hook: scan current session transcript and write token-tracker-state.json
'use strict';
const fs    = require('fs');
const path  = require('path');
const os    = require('os');
const https = require('https');

const CLAUDE_DIR  = path.join(os.homedir(), '.claude');
const CONFIG_PATH = path.join(CLAUDE_DIR, 'token-tracker-config.json');
const STATE_PATH  = path.join(CLAUDE_DIR, 'token-tracker-state.json');
const DEBUG_PATH  = path.join(CLAUDE_DIR, 'token-tracker-debug.json');
const CREDS_PATH  = path.join(CLAUDE_DIR, '.credentials.json');

// Fetch live usage from undocumented /api/oauth/usage endpoint.
// Returns null on any failure — caller falls back to local counting.
function fetchUsage(timeoutMs) {
  return new Promise((resolve) => {
    let token;
    try {
      const creds = JSON.parse(fs.readFileSync(CREDS_PATH, 'utf8'));
      const oa    = creds.claudeAiOauth || {};
      if (!oa.accessToken) return resolve(null);
      if (oa.expiresAt && Date.now() >= oa.expiresAt) return resolve(null);
      token = oa.accessToken;
    } catch (_) { return resolve(null); }

    const req = https.request({
      method: 'GET',
      hostname: 'api.anthropic.com',
      path: '/api/oauth/usage',
      headers: {
        'Authorization': `Bearer ${token}`,
        'anthropic-beta': 'oauth-2025-04-20',
      },
      timeout: timeoutMs,
    }, (res) => {
      if (res.statusCode !== 200) { res.resume(); return resolve(null); }
      let body = '';
      res.setEncoding('utf8');
      res.on('data', c => body += c);
      res.on('end', () => {
        try { resolve(JSON.parse(body)); } catch (_) { resolve(null); }
      });
    });
    req.on('error',   () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.end();
  });
}

let config = { planTokenLimit: 88000, windowHours: 5, contextWindowMax: 200000, burnRateWindowMinutes: 15 };
try { config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); } catch (_) {}

let stdinData = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => stdinData += c);
process.stdin.on('end', async () => {
  // PowerShell 5.1 prepends a UTF-8 BOM (U+FEFF) when piping — strip it
  const raw = stdinData.replace(/^﻿/, '');
  let hookData = {};
  try { hookData = JSON.parse(raw || '{}'); } catch (_) {}

  try { fs.writeFileSync(DEBUG_PATH, JSON.stringify({ parsed: hookData }, null, 2)); } catch (_) {}

  const now          = Date.now();
  const windowMs     = config.windowHours * 60 * 60 * 1000;
  const burnMs       = config.burnRateWindowMinutes * 60 * 1000;

  // If hook provided a transcript path, use it; otherwise find the latest one
  let transcriptPath = hookData.transcript_path;

  if (!transcriptPath) {
    // Fallback: find the most recently modified transcript
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

    // Forward pass: sum billed tokens
    for (const line of lines) {
      if (!line.trim()) continue;
      let e;
      try { e = JSON.parse(line); } catch (_) { continue; }
      if (e.type !== 'assistant' || !e.message || !e.message.usage) continue;

      const ts = new Date(e.timestamp).getTime();
      if (isNaN(ts)) continue;

      const u      = e.message.usage;
      // Count only output tokens — input grows quadratically with context
      const billed = u.output_tokens || 0;
      sessionTokensUsed += billed;
      if (!sessionStart || ts < sessionStart) sessionStart = ts;
      if (ts >= now - burnMs) recentBilled += billed;
    }

    // Backward pass: get latest context window
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

  // Fetch live usage limit from API (5s timeout, falls back to null on failure)
  const usage = await fetchUsage(5000);

  // Load previous state to compute %-burn-rate from API readings
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch (_) {}

  const wStart = sessionStart || now;
  const state  = {
    sessionStart:      wStart,
    windowEnd:         wStart + windowMs,
    sessionTokensUsed,
    burnRatePerMin,
    contextWindowUsed,
    lastUpdated:       now,
  };

  if (usage && usage.five_hour) {
    state.usageLimitPct       = usage.five_hour.utilization;
    state.usageLimitResetsAt  = new Date(usage.five_hour.resets_at).getTime();
    state.usageLimitFetchedAt = now;
    if (usage.seven_day) state.usageLimitSevenDayPct = usage.seven_day.utilization;

    // Track previous reading for %-burn-rate (keep if <30 min old & different)
    const prevPct       = prev.usageLimitPct;
    const prevFetchedAt = prev.usageLimitFetchedAt;
    if (typeof prevPct === 'number' && prevFetchedAt && (now - prevFetchedAt) < 30 * 60_000) {
      state.usageLimitPrevPct       = prevPct;
      state.usageLimitPrevFetchedAt = prevFetchedAt;
    }
  }

  try { fs.writeFileSync(STATE_PATH, JSON.stringify(state)); } catch (_) {}
  process.exit(0);
});
```

---

## File 4 — `~/.claude/settings.json` (merge keys)

Merge the two top-level keys below into your existing `settings.json`. Replace `<USERNAME>` with your username. **Windows: forward slashes only** (see "Path gotcha" above).

### Windows example
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

### macOS / Linux example
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

If you already have `hooks` or `statusLine` in `settings.json`, **merge** rather than overwrite — keep your other entries.

---

## Install (automated)

Use the provided installer scripts to avoid touching files manually.

### Windows (PowerShell)
```powershell
# Run from the folder containing the installer:
powershell -ExecutionPolicy Bypass -File .\install-token-statusline.ps1
```

### macOS / Linux (bash)
```bash
bash install-token-statusline.sh
```

Both scripts are idempotent — safe to re-run. They merge `settings.json` instead of overwriting it, and skip `token-tracker-config.json` if one already exists.

---

## Output reference

```
● Tokens [██████░░░░] 12K/88K left │ ■ Status ● ALIVE │ ▲ Burn ~5K/m │ ◆ Usage Limit [████░░░░] 45% (7d:12%) │ ✦ ETA → 11:48 PM │ ◷ Reset ↺ 4h45m
```

| Glyph | Section | Signature color | What it shows |
|---|---|---|---|
| `●` | Tokens | green | Output tokens used this session / tokens remaining before 95% cap; bar fills toward cap |
| `■` | Status | green/red | **ALIVE** if usage will hit reset before 95%; **DEAD** if 95% comes first |
| `▲` | Burn | orange | Output tokens/min over the last `burnRateWindowMinutes` |
| `◆` | Usage Limit | cyan | Live 5h utilization % from Anthropic API (+ 7-day % if available); falls back to local estimate |
| `✦` | ETA | magenta | Wall-clock time when usage hits 95% (12-hour format); uses API %-delta rate when available |
| `◷` | Reset | blue | Countdown until the 5h window resets; uses API `resets_at` when available |

---

## Color logic (adaptive by level)

Bar fills + value colors use a 4-step ramp on every ratio-based metric:

| Level | Threshold | Color |
|---|---|---|
| Safe | <50% | signature (green / cyan) |
| Warning | 50–75% | yellow |
| Heavy | 75–90% | orange |
| Critical | ≥90% | red |

Burn rate uses absolute thresholds (tokens/min):

| Range | Color |
|---|---|
| 0 | dim gray (idle) |
| 1 – 4 999 | green |
| 5 000 – 14 999 | yellow |
| 15 000 – 29 999 | orange |
| ≥ 30 000 | red |

ETA color (duration-based):

| Remaining | Color |
|---|---|
| > 1 h | green |
| 30 m – 1 h | yellow |
| < 30 m | red |

---

## How it works (cache + scan + API)

- **Statusline render** (`token-statusline.js`) runs every time Claude Code re-paints the bottom bar.
  - If `token-tracker-state.json` is **< 60 s old** → reuse it. Cheap.
  - Else → scan the most recently modified `.jsonl` transcript under `~/.claude/projects/`, recompute, write state, then render. Preserves any API fields already in state.
- **Stop hook** (`update-token-state.js`) fires when an assistant turn ends.
  - Claude Code feeds it the current `transcript_path` over stdin so it scans the right session.
  - Also calls `GET /api/oauth/usage` (5 s timeout) using the OAuth token from `~/.claude/.credentials.json`.
  - Writes `five_hour.utilization`, `five_hour.resets_at`, and `seven_day.utilization` into state.
  - Tracks two consecutive API readings to compute a live %-per-minute burn rate for ETA.
- `token-tracker-state.json` is created automatically. Don't edit it by hand.
- `token-tracker-debug.json` records the last hook payload — only useful for troubleshooting; safe to ignore or delete.

---

## ETA formula

**With live API data (preferred):**
```
pctPerMin = (usageLimitPct - prevPct) / minutesBetweenReadings
etaMs     = ((95 - usageLimitPct) / pctPerMin) × 60 000
```

**Fallback (no API / first reading):**
```
cutoff    = planTokenLimit × 0.95
remaining = cutoff − sessionTokensUsed
etaMs     = remaining ÷ burnRatePerMin × 60 000
```

`Status = DEAD` when `etaMs < resetMs` **and** usage is already past `DEAD_MIN_PCT` (50%) — the limit hits 95% before the reset window closes. Below 50% the rate is extrapolated from too few samples to trust, so the status stays ALIVE. A measured `planPct >= 95` is always DEAD regardless of the threshold.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Statusline shows nothing | `node` not on PATH, or path in `settings.json` is wrong | Run `node ~/.claude/scripts/token-statusline.js` — fix whichever error it prints |
| Hook error: `Cannot find module 'C:\Users<you>.claudescripts...'` | Windows: backslashes in `settings.json` got eaten by bash | Use forward slashes (`C:/Users/...`) in `settings.json` |
| Usage Limit always shows `(local ~…)` | OAuth token missing / expired, or no internet | Log in to Claude Code and ensure `~/.claude/.credentials.json` contains a valid `claudeAiOauth.accessToken` |
| Statusline frozen / not updating | 60 s state cache | Send any message; next render refreshes. Or delete `~/.claude/token-tracker-state.json` to force rescan |
| Colors look wrong (raw escape codes) | Terminal lacks 24-bit ANSI | Use Windows Terminal, iTerm2, or a recent VS Code integrated terminal |
| Numbers look stale on a fresh session | Script picks the most recently modified `.jsonl` globally | Self-corrects on the next render once your new session writes its first event |

---

## Customization quick reference

| Change | File | What to edit |
|---|---|---|
| Reset window length | `token-tracker-config.json` | `windowHours` |
| Model context size | `token-tracker-config.json` | `contextWindowMax` |
| Burn rate sliding window | `token-tracker-config.json` | `burnRateWindowMinutes` |
| Token budget fallback | `token-tracker-config.json` | `planTokenLimit` |
| 24-hour clock instead of AM/PM | `token-statusline.js` → `fmtClock` | Replace `${h12}:${mm} ${ap}` with `${String(h24).padStart(2,'0')}:${mm}` |
| Different theme palette | `token-statusline.js` → `C = {...}` | Swap the `\x1b[38;2;R;G;Bm` triples for your theme's hex values |
| State cache freshness | `token-statusline.js` | `STATE_MAX_AGE` (ms) |
| Critical threshold | `token-statusline.js` → `levelColor` | Adjust the four `if (ratio >= …)` lines |

---

## Verification checklist

- [ ] `node --version` ≥ 18
- [ ] All four files written at the paths above
- [ ] Windows: paths in `settings.json` use forward slashes
- [ ] `node ~/.claude/scripts/token-statusline.js` prints a colored line
- [ ] Restart Claude Code; statusline appears at the bottom of the terminal
- [ ] After one assistant turn finishes, `~/.claude/token-tracker-state.json` exists with non-zero `sessionTokensUsed`
- [ ] After the Stop hook fires, state has `usageLimitPct` (live API) — if missing, check credentials

If every box checks, the install is identical to the source machine.
