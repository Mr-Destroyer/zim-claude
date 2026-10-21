<#
.SYNOPSIS
  Run Claude Code against the local LiteLLM -> Token Juice route on Windows.

.DESCRIPTION
  Windows counterpart of scripts/zim-claude. Every argument is forwarded
  verbatim to claude.exe. This script deliberately parses NO options of its own:
  `zim-claude --help`, `zim-claude mcp list`, `zim-claude -p "..."` and every
  other Claude Code flag/subcommand must reach claude unchanged. Configure it
  through environment variables only.

    LITELLM_ENV_FILE            profile to source   (default %USERPROFILE%\tokenjuice\source)
    LITELLM_PORT                proxy port         (default: the port in the profile)
    ZIM_CLAUDE_BIN              claude executable  (default: claude on PATH)
    ZIM_CLAUDE_NO_PROXY=1       never touch the proxy
    ZIM_CLAUDE_REQUIRE_PROXY=1  hard-fail if the proxy is not healthy
    ZIM_CLAUDE_NO_UPDATE=1      never auto-update

.NOTES
  Invoke it through the zim-claude.cmd shim, which is what lands on PATH. The
  shim is required, not cosmetic: a .ps1 cannot be executed by name from cmd or
  from another program's subprocess call the way an .exe/.cmd can.
#>

[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ClaudeArgs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# --- configurable ------------------------------------------------------------
$SelfDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($env:LITELLM_ENV_FILE) { $EnvFile = $env:LITELLM_ENV_FILE }
else { $EnvFile = Join-Path $env:USERPROFILE 'tokenjuice\source' }

# The profile chooses the port. Only an explicit LITELLM_PORT overrides it:
# the installer probes for a port whose proxy accepts this profile's token, so
# a hardcoded default here would check (and start) a proxy the profile does
# not use, and warn on every run on a machine where another proxy owns that port.
$portExplicit = -not [string]::IsNullOrEmpty($env:LITELLM_PORT)
$Port = 4000
if ($portExplicit) { $Port = [int]$env:LITELLM_PORT }

$Service = Join-Path $SelfDir 'start-proxies.ps1'

if ($env:ZIM_CLAUDE_NO_PROXY) { $NoProxy = $env:ZIM_CLAUDE_NO_PROXY } else { $NoProxy = '0' }
if ($env:ZIM_CLAUDE_REQUIRE_PROXY) { $RequireProxy = $env:ZIM_CLAUDE_REQUIRE_PROXY } else { $RequireProxy = '0' }

# All diagnostics go to stderr: `zim-claude -p "x" --output-format json | ConvertFrom-Json`
# must stay parseable, so nothing here may write to stdout.
function Write-Die  { param([string]$m) [Console]::Error.WriteLine("[zim-claude] $m"); exit 2 }
function Write-Warn { param([string]$m) [Console]::Error.WriteLine("[zim-claude] $m") }
function Write-Info { param([string]$m) [Console]::Error.WriteLine("[zim-claude] $m") }

# --- locate claude -----------------------------------------------------------

if ($env:ZIM_CLAUDE_BIN) {
  $ClaudeBin = $env:ZIM_CLAUDE_BIN
} else {
  $cmd = Get-Command claude -ErrorAction SilentlyContinue
  if ($cmd) { $ClaudeBin = $cmd.Source }
  else {
    # PATH has not been refreshed in this session. Look where Claude Code's
    # installers actually put it rather than failing: a terminal opened before
    # the installer ran has a stale PATH, and being told to open a new one is
    # a poor answer when the binary is sitting right there.
    $candidates = @(
      (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
      (Join-Path $env:APPDATA 'npm\claude.cmd'),
      (Join-Path $env:APPDATA 'Python\Scripts\claude.exe')
    )
    $ClaudeBin = $null
    foreach ($c in $candidates) {
      if (Test-Path -LiteralPath $c) { $ClaudeBin = $c; break }
    }
  }
}

if (-not $ClaudeBin) {
  Write-Die "claude not found on PATH. Install Claude Code, or set ZIM_CLAUDE_BIN."
}
if (-not (Test-Path -LiteralPath $ClaudeBin)) {
  Write-Die "claude is not executable: $ClaudeBin"
}

# --- load the profile --------------------------------------------------------

# Fail CLOSED. Without the profile, claude would silently use whatever
# ANTHROPIC_* this shell already exports - a session against the wrong provider,
# with the wrong model, and no indication anything was off.
if (-not (Test-Path -LiteralPath $EnvFile)) {
  Write-Die "env file not found: $EnvFile
       Refusing to run: without it, claude would silently use whatever
       ANTHROPIC_* variables your shell already exports.
       Fix:  set LITELLM_ENV_FILE to a real profile, or re-run
       windows\win-install.bat."
}

# Captured BEFORE the assignments, so the override can be reported.
$prevBaseUrl = [Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')

# Parse the POSIX `export NAME="value"` profile. Kept in bash syntax so the
# same file works on Linux, in Git Bash, and here.
$profileVars = @{}
foreach ($line in Get-Content -LiteralPath $EnvFile) {
  if ($line -match '^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?(.*?)"?\s*$') {
    $profileVars[$Matches[1]] = $Matches[2]
  }
}

if (-not $profileVars.ContainsKey('ANTHROPIC_AUTH_TOKEN') -or
    [string]::IsNullOrEmpty($profileVars['ANTHROPIC_AUTH_TOKEN'])) {
  Write-Die "$EnvFile did not set ANTHROPIC_AUTH_TOKEN - refusing to start."
}

# Scope the variables to this process only; the parent shell is untouched, so
# plain `claude` keeps using whatever provider it used before.
foreach ($k in $profileVars.Keys) {
  [Environment]::SetEnvironmentVariable($k, $profileVars[$k], 'Process')
}

# Claude Code names its background and /model-picker calls after Anthropic tiers
# (haiku / sonnet / opus). The proxy only knows the model names in
# %USERPROFILE%\tokenjuice\litellm-config.yaml, so point every tier at the model
# the profile selected - otherwise `/model sonnet` asks the proxy for
# "claude-sonnet-4-5" and gets a 404. A tier the profile names explicitly wins.
$modelName = $profileVars['ANTHROPIC_MODEL']
if (-not [string]::IsNullOrEmpty($modelName)) {
  foreach ($tier in @('ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
                      'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL')) {
    if (-not $profileVars.ContainsKey($tier) -or [string]::IsNullOrEmpty($profileVars[$tier])) {
      [Environment]::SetEnvironmentVariable($tier, $modelName, 'Process')
    }
  }
}

$baseUrl = $profileVars['ANTHROPIC_BASE_URL']
if ($prevBaseUrl -and $prevBaseUrl -ne $baseUrl) {
  Write-Warn "overriding inherited ANTHROPIC_BASE_URL=$prevBaseUrl -> $baseUrl"
}

# Follow the profile's port unless the caller named one explicitly.
if (-not $portExplicit -and $baseUrl -match ':([0-9]+)') {
  $Port = [int]$Matches[1]
}

# --- only manage a proxy when the profile points at the local one ------------

if ($baseUrl -notmatch "localhost:$Port" -and $baseUrl -notmatch "127\.0\.0\.1:$Port") {
  Write-Warn "ANTHROPIC_BASE_URL=$baseUrl is not the local proxy on :$Port;"
  Write-Warn "skipping the proxy start-up check."
  $NoProxy = '1'
}

function Test-ProxyHealthy {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health/liveliness" `
                           -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

function Ensure-Proxy {
  if ($NoProxy -eq '1') { return $true }
  if (Test-ProxyHealthy) { return $true }

  if (-not (Test-Path -LiteralPath $Service)) {
    Write-Warn "proxy not answering on :$Port, and no manager at $Service."
    Write-Warn "Start it yourself, or set ZIM_CLAUDE_NO_PROXY=1."
    return $false
  }

  Write-Info "LiteLLM proxy not answering on :$Port - starting it..."
  # A subprocess, never dot-sourced: start-proxies.ps1 ends in a switch that
  # runs on load and calls exit. The port is passed because the profile, not
  # this script's default, chose it; the variable is restored afterwards so
  # claude does not inherit our bookkeeping.
  $prevPortEnv = $env:LITELLM_PORT
  $env:LITELLM_PORT = "$Port"
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Service start -Which cli | Out-Null
  } finally {
    if ([string]::IsNullOrEmpty($prevPortEnv)) { Remove-Item Env:\LITELLM_PORT -ErrorAction SilentlyContinue }
    else { $env:LITELLM_PORT = $prevPortEnv }
  }
  if (Test-ProxyHealthy) { Write-Info "proxy is up."; return $true }

  Write-Warn "could not start the proxy - see the log under .local\share\zim-claude\logs\"
  Write-Warn "continuing anyway; claude will report the connection error."
  return $false
}

Ensure-Proxy | Out-Null

if ($RequireProxy -eq '1' -and -not (Test-ProxyHealthy)) {
  Write-Die "proxy is not healthy on :$Port and ZIM_CLAUDE_REQUIRE_PROXY=1."
}

# --- self-update -------------------------------------------------------------

# Bring the installed package up to date in the background. Detached so it can
# never delay, block or fail this session; the updater rate-limits itself,
# refuses a dirty checkout, and only fast-forwards.
$noUpdate = $env:ZIM_CLAUDE_NO_UPDATE
if ($noUpdate -ne '1') {
  $updater = Join-Path $SelfDir 'zim-claude-update.ps1'
  if (Test-Path -LiteralPath $updater) {
    try {
      # Hidden window, no wait: the session must not depend on its outcome.
      Start-Process -FilePath 'powershell' `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updater) `
                    -WindowStyle Hidden | Out-Null
    } catch {
      # An updater that cannot start is not the user's problem; the session
      # is already healthy by this point.
    }
  }
}

# --- hand off ----------------------------------------------------------------

# Forward every argument verbatim and pass claude's exit code through untouched.
# `exit $LASTEXITCODE` matters: without it this script would report 0 even when
# claude failed, which would break `zim-claude -p ... && next-step` in CI.
& $ClaudeBin @ClaudeArgs
exit $LASTEXITCODE
