# Claude Code Token Statusline — Windows installer
# Idempotent: safe to re-run. Merges settings.json instead of overwriting.
# Usage:  powershell -ExecutionPolicy Bypass -File .\install-token-statusline.ps1

$ErrorActionPreference = 'Stop'

# Verify prerequisites
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  Write-Error "Node.js is required. Install from https://nodejs.org (v18+)."
}

$claude         = Join-Path $HOME '.claude'
$scripts        = Join-Path $claude 'scripts'
$scriptsForward = $scripts -replace '\\','/'
$utf8NoBom      = [System.Text.UTF8Encoding]::new($false)

New-Item -ItemType Directory -Force $scripts | Out-Null
Write-Host "-> Writing files into $claude"

# ── File 1: token-tracker-config.json ────────────────────────────────────────
$configPath = Join-Path $claude 'token-tracker-config.json'
if (-not (Test-Path $configPath)) {
  $configJson = '{
  "planTokenLimit": 900000,
  "windowHours": 5,
  "contextWindowMax": 200000,
  "burnRateWindowMinutes": 15
}'
  [System.IO.File]::WriteAllText($configPath, $configJson, $utf8NoBom)
  Write-Host "  Wrote token-tracker-config.json"
} else {
  Write-Host "  Skipped token-tracker-config.json (already exists, keeping your settings)"
}

# ── File 2: scripts/token-statusline.js ──────────────────────────────────────
$statuslineJs = @'
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
    const billed = u.output_tokens || 0;
    if (ts >= now - windowMs) sessionTokensUsed += billed;
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

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch (_) {}

  const wStart = sessionStart || now;
  const state  = {
    sessionStart: wStart, windowEnd: wStart + windowMs,
    sessionTokensUsed, burnRatePerMin, contextWindowUsed, lastUpdated: now,
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

const now = Date.now();
let state = null;
try { state = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch (_) {}
if (!state || (now - (state.lastUpdated || 0)) > STATE_MAX_AGE) {
  state = scanCurrentSession(now);
}

const planLimit = config.planTokenLimit || 900_000;
const {
  sessionTokensUsed, burnRatePerMin, contextWindowUsed, windowEnd,
  usageLimitPct, usageLimitResetsAt, usageLimitFetchedAt,
  usageLimitPrevPct, usageLimitPrevFetchedAt,
} = state;

const hasLive   = typeof usageLimitPct === 'number';
const planPct   = hasLive
  ? Math.min(Math.round(usageLimitPct), 100)
  : Math.min(Math.round((sessionTokensUsed / planLimit) * 100), 100);
const planRatio = planPct / 100;

const resetMs = hasLive && usageLimitResetsAt
  ? Math.max(usageLimitResetsAt - now, 0)
  : Math.max((windowEnd || now) - now, 0);

const burnStr = burnRatePerMin > 0 ? `${fmtK(burnRatePerMin)}/m` : '--';

let etaMs  = Infinity;
let isDead = false;

if (planPct >= 95) {
  isDead = true;
  etaMs  = 0;
} else if (hasLive && typeof usageLimitPrevPct === 'number' && usageLimitPrevFetchedAt) {
  const dPct = usageLimitPct - usageLimitPrevPct;
  const dMin = (usageLimitFetchedAt - usageLimitPrevFetchedAt) / 60_000;
  const pctPerMin = dMin > 0 ? dPct / dMin : 0;
  if (pctPerMin > 0) {
    etaMs  = ((95 - usageLimitPct) / pctPerMin) * 60_000;
    isDead = etaMs < resetMs;
  }
} else if (!hasLive && burnRatePerMin > 0) {
  const cutoff    = planLimit * 0.95;
  const remaining = cutoff - sessionTokensUsed;
  etaMs  = (remaining / burnRatePerMin) * 60_000;
  isDead = etaMs < resetMs;
}

const etaStr = fmtClock(etaMs, now);

const remainingPct    = Math.max(0, 95 - planPct);
const remainingTokens = Math.round((remainingPct / 100) * planLimit);
const tokenRatio      = sessionTokensUsed / Math.max(sessionTokensUsed + remainingTokens, 1);
const tokenBarStr     = colorBar(tokenRatio, 10, C.green);
const tokenNumColor   = levelColor(tokenRatio, C.green);
const tokenPart       = `${C.green}● ${C.fg}Tokens ${tokenBarStr} ${tokenNumColor}${fmtK(sessionTokensUsed)}${C.dimFg}/${C.green}${fmtK(remainingTokens)}${C.dimFg} left${C.reset}`;

const planBarStr   = colorBar(planRatio, 8, C.cyan);
const planNumColor = levelColor(planRatio, C.cyan);
const usageDetail  = hasLive
  ? (typeof state.usageLimitSevenDayPct === 'number' ? `${C.dimFg}(7d:${Math.round(state.usageLimitSevenDayPct)}%)` : '')
  : `${C.dimFg}(local ~${fmtK(sessionTokensUsed)}/${fmtK(planLimit)})`;
const ctxPart      = `${C.cyan}◆ ${C.fg}Usage Limit ${planBarStr} ${planNumColor}${planPct}% ${usageDetail}${C.reset}`;

const burnPart = `${C.orange}▲ ${C.fg}Burn ${burnColor(burnRatePerMin)}~${burnStr}${C.reset}`;

const etaColor = etaMs <= 0 ? C.red : etaMs < 30 * 60_000 ? C.red : etaMs < 60 * 60_000 ? C.yellow : C.green;
const etaPart  = `${C.magenta}✦ ${C.fg}ETA ${C.magenta}→ ${etaColor}${etaStr}${C.reset}`;

const resetPart = `${C.blue}◷ ${C.fg}Reset ${C.blue}↺ ${C.blue}${fmtTime(resetMs)}${C.reset}`;

const statusPart = isDead
  ? `${C.red}■ ${C.fg}Status ${C.bold}${C.red}✗ DEAD${C.reset}`
  : `${C.green}■ ${C.fg}Status ${C.bold}${C.green}● ALIVE${C.reset}`;

process.stdout.write([tokenPart, statusPart, burnPart, ctxPart, etaPart, resetPart].join(SEP));
process.exit(0);
'@
[System.IO.File]::WriteAllText((Join-Path $scripts 'token-statusline.js'), $statuslineJs, $utf8NoBom)

# ── File 3: scripts/update-token-state.js ────────────────────────────────────
$hookJs = @'
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
  // PowerShell 5.1 prepends a UTF-8 BOM when piping — strip it
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
      const billed = u.output_tokens || 0;
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

  const usage = await fetchUsage(5000);

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch (_) {}

  const wStart = sessionStart || now;
  const state  = {
    sessionStart: wStart, windowEnd: wStart + windowMs,
    sessionTokensUsed, burnRatePerMin, contextWindowUsed, lastUpdated: now,
  };

  if (usage && usage.five_hour) {
    state.usageLimitPct       = usage.five_hour.utilization;
    state.usageLimitResetsAt  = new Date(usage.five_hour.resets_at).getTime();
    state.usageLimitFetchedAt = now;
    if (usage.seven_day) state.usageLimitSevenDayPct = usage.seven_day.utilization;

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
'@
[System.IO.File]::WriteAllText((Join-Path $scripts 'update-token-state.js'), $hookJs, $utf8NoBom)

# ── File 4: merge settings.json via Node (idempotent, preserves existing keys) ──
$mergeJs = @'
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
'@
$mergeTmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("merge-statusline-" + [Guid]::NewGuid().ToString() + ".js"))
[System.IO.File]::WriteAllText($mergeTmp, $mergeJs, $utf8NoBom)
$settingsPath = Join-Path $claude 'settings.json'
$statusCmd    = "node $scriptsForward/token-statusline.js"
$hookCmd      = "node $scriptsForward/update-token-state.js"
& node $mergeTmp $settingsPath $statusCmd $hookCmd
Remove-Item $mergeTmp

# ── Verify ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Preview:"
& node (Join-Path $scripts 'token-statusline.js')
Write-Host ""
Write-Host ""
Write-Host "Installed. Restart Claude Code to see the statusline."
