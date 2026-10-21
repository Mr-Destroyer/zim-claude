<#
.SYNOPSIS
  Prove the Claude Desktop gateway is reachable and behaving on Windows.

.DESCRIPTION
  Windows counterpart of claude-desktop-integration/verify.sh. Exercises the two
  endpoints Claude Desktop actually uses:

    GET  /v1/models    (model discovery / picker)
    POST /v1/messages  (Anthropic Messages API)

  If /v1/models does not return a claude*-named model, the app silently drops
  the deployment from its picker, so that check is the one that matters most.

.PARAMETER Model
  Model id to exercise. Defaults to claude-opus-5-5, the name the desktop proxy
  exposes the upstream model under.

.EXAMPLE
  .\verify.ps1
  .\verify.ps1 claude-opus-5-5
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Model = 'claude-opus-5-5'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ($env:CLAUDE_DESKTOP_PORT) { $Port = [int]$env:CLAUDE_DESKTOP_PORT } else { $Port = 4002 }
if ($env:CLAUDE_DESKTOP_LITELLM_KEY) { $Key = $env:CLAUDE_DESKTOP_LITELLM_KEY }
else { $Key = 'sk-claude-desktop-local' }

$Base = "http://127.0.0.1:$Port"

function Write-Pass { param([string]$m) Write-Host "  ok  $m" -ForegroundColor Green }
function Write-Fail { param([string]$m) Write-Host " fail $m" -ForegroundColor Red }
function Write-Hdr  { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }

# --- 1. health ---------------------------------------------------------------

Write-Hdr "1. proxy health ($Base/health/liveliness)"
$healthy = $false
try {
  $r = Invoke-WebRequest -Uri "$Base/health/liveliness" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
  if ($r.StatusCode -eq 200) { Write-Pass "healthy (HTTP 200)"; $healthy = $true }
  else { Write-Fail "HTTP $($r.StatusCode)" }
} catch {
  Write-Fail "unreachable - is the proxy running? try: start-proxies.ps1 start -Which desktop"
}
if (-not $healthy) { exit 1 }

# --- 2. model discovery ------------------------------------------------------

Write-Hdr "2. model discovery ($Base/v1/models)"
try {
  $r = Invoke-WebRequest -Uri "$Base/v1/models" -UseBasicParsing -TimeoutSec 8 `
        -Headers @{ Authorization = "Bearer $Key" } -ErrorAction Stop
  $body = $r.Content
  Write-Host "    $body"
  if ($body -match 'claude') {
    Write-Pass "picker will show claude-* model(s)"
  } else {
    Write-Fail "no claude/anthropic-named model - Claude Desktop would reject the deployment"
  }
} catch {
  Write-Fail "request failed: $_"
}

# --- 3. Anthropic Messages API ----------------------------------------------

Write-Hdr "3. Anthropic Messages API (POST $Base/v1/messages, model=$Model)"
$payload = @{
  model      = $Model
  max_tokens = 32
  messages   = @(@{ role = 'user'; content = 'Reply with the single word: ready' })
} | ConvertTo-Json -Depth 5 -Compress

try {
  $r = Invoke-WebRequest -Uri "$Base/v1/messages" -Method Post -UseBasicParsing -TimeoutSec 45 `
        -Headers @{ 'x-api-key' = $Key } -ContentType 'application/json' `
        -Body $payload -ErrorAction Stop
  Write-Pass "HTTP $($r.StatusCode)"
  $snippet = [string]$r.Content
  if ($snippet.Length -gt 400) { $snippet = $snippet.Substring(0, 400) }
  Write-Host "    $snippet"
} catch {
  Write-Fail "request failed: $_"
  # Invoke-WebRequest throws on non-2xx; the body is on the exception.
  $resp = $_.Exception.Response
  if ($resp) {
    try {
      $reader = New-Object IO.StreamReader($resp.GetResponseStream())
      $errBody = $reader.ReadToEnd()
      if ($errBody.Length -gt 600) { $errBody = $errBody.Substring(0, 600) }
      Write-Host "    $errBody"
    } catch { }
  }
}

# --- next steps --------------------------------------------------------------

Write-Host ""
Write-Hdr "Next: point Claude Desktop at this gateway"
Write-Host "  Developer menu -> Configure Third-Party Inference..."
Write-Host "    Inference provider : Gateway"
Write-Host "    Gateway base URL   : $Base"
Write-Host "    Gateway API key    : $Key"
Write-Host "    Gateway auth scheme: bearer"
Write-Host "  Apply, then restart Claude Desktop."
