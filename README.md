# Claude Code Token Statusline

A colored token-usage statusline for Claude Code's terminal bottom bar, styled with One Dark Pro colors.

```
● Tokens [██████░░░░] 12K/88K left │ ■ Status ● ALIVE │ ▲ Burn ~5K/m │ ◆ Usage Limit [████░░░░] 45% (7d:12%) │ ✦ ETA → 11:48 PM │ ◷ Reset ↺ 4h45m
```

| Section | Color | What it shows |
|---|---|---|
| `● Tokens` | green | Output tokens used / remaining before 95% cap |
| `■ Status` | green/red | **ALIVE** if reset comes before cap; **DEAD** if cap hits first |
| `▲ Burn` | orange | Tokens/min over the last 15 min |
| `◆ Usage Limit` | cyan | Live 5h utilization % from Anthropic API (falls back to local estimate) |
| `✦ ETA` | magenta | Wall-clock time when usage hits 95% |
| `◷ Reset` | blue | Countdown until the 5h window resets |

---

## Prerequisites

- **Node.js 18+** — verify with `node --version`
- **Claude Code** installed, with `~/.claude/` present
- Terminal with 24-bit ANSI color (Windows Terminal, iTerm2, VS Code integrated terminal)

---

## Quick install (recommended)

Clone or download this repo, then run the installer for your platform. Both scripts are idempotent — safe to re-run.

### Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File .\install-token-statusline.ps1
```

### macOS / Linux

```bash
bash install-token-statusline.sh
```

After the script finishes, **restart Claude Code**. The statusline appears at the bottom of the terminal.

---

## What the installer does

The script writes four things into `~/.claude/`:

```
~/.claude/
├── settings.json                  ← merged (statusLine + Stop hook added)
├── token-tracker-config.json      ← created (skipped if already exists)
└── scripts/
    ├── token-statusline.js        ← renders the statusline
    └── update-token-state.js      ← Stop hook: scans transcript + calls API
```

`~` is `C:\Users\<you>` on Windows, `/Users/<you>` on macOS, `/home/<you>` on Linux.

---

## Manual install

If you prefer to install without running the script, follow these steps.

### Step 1 — Create the scripts directory

```bash
mkdir -p ~/.claude/scripts
```

### Step 2 — Copy the config file

Create `~/.claude/token-tracker-config.json`:

```json
{
  "planTokenLimit": 900000,
  "windowHours": 5,
  "contextWindowMax": 200000,
  "burnRateWindowMinutes": 15
}
```

### Step 3 — Copy the scripts

Copy the contents of [claude-code-token-statusline-setup.md](claude-code-token-statusline-setup.md) — **File 2** goes to `~/.claude/scripts/token-statusline.js` and **File 3** goes to `~/.claude/scripts/update-token-state.js`.

### Step 4 — Update settings.json

Merge the following into `~/.claude/settings.json`. Replace `<USERNAME>` with your username.

**Windows** (forward slashes required — see note below):

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

**macOS / Linux**:

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

If you already have `hooks` or `statusLine` keys, **merge** rather than replace — keep your existing entries.

### Step 5 — Restart Claude Code

The statusline appears at the bottom of the terminal on the next launch.

---

## Windows path note

Always use **forward slashes** in `settings.json` paths on Windows:

```
✅  node C:/Users/<you>/.claude/scripts/token-statusline.js
❌  node C:\\Users\\<you>\\.claude\\scripts\\token-statusline.js
```

Claude Code routes hook and statusline commands through bash on Windows. Backslashes get interpreted as escape sequences (`\U`, `\s`, `\.`) and silently stripped — the path collapses and Node throws `Cannot find module`. Forward slashes work natively on Windows Node.js.

---

## Verification

After install, confirm everything works:

- [ ] `node --version` prints 18 or higher
- [ ] `node ~/.claude/scripts/token-statusline.js` prints a colored line
- [ ] Restart Claude Code — statusline appears at the bottom
- [ ] After one assistant turn, `~/.claude/token-tracker-state.json` exists with non-zero `sessionTokensUsed`
- [ ] State has `usageLimitPct` after the Stop hook fires (needs valid OAuth credentials)

---

## Configuration

Edit `~/.claude/token-tracker-config.json` to tune the display:

| Key | Default | Effect |
|---|---|---|
| `windowHours` | `5` | Session reset window length (Claude Code plan resets every 5h) |
| `contextWindowMax` | `200000` | Model context size for display |
| `burnRateWindowMinutes` | `15` | Sliding window for tokens/min calculation |
| `planTokenLimit` | `900000` | Output-token budget fallback when API data is unavailable |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Statusline shows nothing | `node` not on PATH or wrong path in `settings.json` | Run `node ~/.claude/scripts/token-statusline.js` and fix the error |
| `Cannot find module 'C:\Users<you>.claudescripts...'` | Windows backslashes eaten by bash | Use forward slashes in `settings.json` |
| Usage Limit always shows `(local ~…)` | OAuth token missing or expired | Log in to Claude Code; check `~/.claude/.credentials.json` has a valid `claudeAiOauth.accessToken` |
| Statusline frozen / stale | 60s state cache | Send any message to trigger a refresh, or delete `~/.claude/token-tracker-state.json` |
| Raw escape codes instead of colors | Terminal lacks 24-bit ANSI | Use Windows Terminal, iTerm2, or VS Code integrated terminal |

---

## How it works

- **Statusline** (`token-statusline.js`) runs every time Claude Code repaints the bottom bar. If `token-tracker-state.json` is less than 60 seconds old it reuses it (fast path). Otherwise it scans the most recently modified `.jsonl` transcript under `~/.claude/projects/`, refreshes the state, and renders.
- **Stop hook** (`update-token-state.js`) fires after each assistant turn. It reads the transcript path from stdin, scans it for token usage, then calls `GET /api/oauth/usage` (5s timeout) using the OAuth token from `~/.claude/.credentials.json` to get live utilization data. Results are written to `~/.claude/token-tracker-state.json`.
