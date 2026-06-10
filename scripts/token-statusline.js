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

function resetsAtMs(value) {
  if (typeof value === 'number') return value < 1e12 ? value * 1000 : value;
  if (typeof value === 'string') {
    const ms = new Date(value).getTime();
    return isNaN(ms) ? null : ms;
  }
  return null;
}

function applyRateLimits(state, rateLimits, now) {
  if (!rateLimits?.five_hour) return state;
  const pct = rateLimits.five_hour.used_percentage ?? rateLimits.five_hour.utilization;
  if (typeof pct !== 'number') return state;

  const prevPct       = state.usageLimitPct;
  const prevFetchedAt = state.usageLimitFetchedAt;

  state.usageLimitPct       = pct;
  state.usageLimitFetchedAt = now;
  const resetMs = resetsAtMs(rateLimits.five_hour.resets_at);
  if (resetMs) state.usageLimitResetsAt = resetMs;

  const seven = rateLimits.seven_day?.used_percentage ?? rateLimits.seven_day?.utilization;
  if (typeof seven === 'number') state.usageLimitSevenDayPct = seven;

  if (typeof prevPct === 'number' && prevFetchedAt && (now - prevFetchedAt) < 30 * 60_000) {
    state.usageLimitPrevPct       = prevPct;
    state.usageLimitPrevFetchedAt = prevFetchedAt;
  }
  return state;
}

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

function render(payload) {
const now = Date.now();
let state = null;
try { state = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch (_) {}
if (!state || (now - (state.lastUpdated || 0)) > STATE_MAX_AGE) {
  state = scanCurrentSession(now);
}
state = applyRateLimits(state, payload.rate_limits, now);
if (payload.rate_limits?.five_hour) {
  try { fs.writeFileSync(STATE_PATH, JSON.stringify(state)); } catch (_) {}
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
}

let renderDone = false;
function finishRender(stdinData) {
  if (renderDone) return;
  renderDone = true;
  let payload = {};
  try { payload = JSON.parse(stdinData.replace(/^\uFEFF/, '').trim() || '{}'); } catch (_) {}
  render(payload);
  process.exit(0);
}

if (process.stdin.isTTY) {
  render({});
  process.exit(0);
}

let stdinData = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => stdinData += c);
process.stdin.on('end', () => finishRender(stdinData));
process.stdin.resume();
setTimeout(() => finishRender(stdinData), 1500);
