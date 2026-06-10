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

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8')); } catch (_) {}

  const wStart = sessionStart || now;
  const state  = {
    sessionStart: wStart, windowEnd: wStart + windowMs,
    sessionTokensUsed, burnRatePerMin, contextWindowUsed, lastUpdated: now,
  };

  function applyLiveUsage(pct, resetsAt, sevenDayPct) {
    state.usageLimitPct       = pct;
    state.usageLimitFetchedAt = now;
    if (resetsAt) state.usageLimitResetsAt = resetsAt;
    if (typeof sevenDayPct === 'number') state.usageLimitSevenDayPct = sevenDayPct;
    const prevPct       = prev.usageLimitPct;
    const prevFetchedAt = prev.usageLimitFetchedAt;
    if (typeof prevPct === 'number' && prevFetchedAt && (now - prevFetchedAt) < 30 * 60_000) {
      state.usageLimitPrevPct       = prevPct;
      state.usageLimitPrevFetchedAt = prevFetchedAt;
    }
  }

  const rl = hookData.rate_limits;
  if (rl?.five_hour) {
    const pct = rl.five_hour.used_percentage ?? rl.five_hour.utilization;
    if (typeof pct === 'number') {
      let resetsAt = null;
      const ra = rl.five_hour.resets_at;
      if (typeof ra === 'number') resetsAt = ra < 1e12 ? ra * 1000 : ra;
      else if (typeof ra === 'string') resetsAt = new Date(ra).getTime();
      const seven = rl.seven_day?.used_percentage ?? rl.seven_day?.utilization;
      applyLiveUsage(pct, resetsAt, seven);
    }
  } else {
    const usage = await fetchUsage(5000);
    if (usage && usage.five_hour) {
      applyLiveUsage(
        usage.five_hour.utilization,
        new Date(usage.five_hour.resets_at).getTime(),
        usage.seven_day?.utilization,
      );
    }
  }

  try { fs.writeFileSync(STATE_PATH, JSON.stringify(state)); } catch (_) {}
  process.exit(0);
});
