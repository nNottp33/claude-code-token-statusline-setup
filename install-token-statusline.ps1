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


$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Copy-Item (Join-Path $scriptDir 'scripts\token-statusline.js') (Join-Path $scripts 'token-statusline.js') -Force
Copy-Item (Join-Path $scriptDir 'scripts\update-token-state.js') (Join-Path $scripts 'update-token-state.js') -Force
Write-Host "  Wrote token-statusline.js and update-token-state.js"
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

# ── PowerShell profile integration (for Warp) ─────────────────────────────────
$psProfile = $PROFILE.CurrentUserAllHosts
$marker    = '# __claude-code-token-statusline__'
$existing  = if (Test-Path $psProfile) { [System.IO.File]::ReadAllText($psProfile) } else { '' }
if ($existing -notmatch [regex]::Escape($marker)) {
  New-Item -ItemType File -Force -Path $psProfile | Out-Null
  $snippet = @"

$marker
function prompt {
    `$__ct = & node "`$HOME/.claude/scripts/token-statusline.js" 2>`$null
    if (`$__ct) { Write-Host `$__ct }
    "PS `$(`$executionContext.SessionState.Path.CurrentLocation)> "
}
"@
  [System.IO.File]::AppendAllText($psProfile, $snippet, $utf8NoBom)
  Write-Host "  Appended prompt integration to PowerShell profile ($psProfile)"
} else {
  Write-Host "  Skipped PowerShell profile (already patched)"
}

# ── Verify ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Preview:"
& node (Join-Path $scripts 'token-statusline.js')
Write-Host ""
Write-Host ""
Write-Host "Installed. Restart Claude Code to see the statusline."
