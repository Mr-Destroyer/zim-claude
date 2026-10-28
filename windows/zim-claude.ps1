<#
.SYNOPSIS
  Run Claude Code against TokenHarbor on Windows.

.DESCRIPTION
  Windows counterpart of scripts/zim-claude. Every argument is forwarded
  verbatim to claude.exe. This script deliberately parses NO options of its own:
  `zim-claude --help`, `zim-claude mcp list`, `zim-claude -p "..."` and every
  other Claude Code flag/subcommand must reach claude unchanged. Configure it
  through environment variables only.

  Token Juice is down: its unlimited quota ended, so this wrapper no longer
  routes to it. Nothing here reads %USERPROFILE%\tokenjuice\ or the key file
  that ships in the checkout - a tj_ key is refused outright. Every run says so
  once on stderr and offers TokenHarbor instead; the answer is remembered.

    ZIM_CLAUDE_USE_TOKENHARBOR=1  use TokenHarbor without asking
    ZIM_CLAUDE_USE_TOKENHARBOR=0  never use TokenHarbor (exit 2 with the notice)
    ZIM_CLAUDE_API_KEY            key to use; skips the prompt and the cache
                                  (TOKENHARBOR_API_KEY is accepted too)
    ZIM_CLAUDE_MODEL              model id to use; skips the picker
    ZIM_CLAUDE_BASE_URL           API base URL  (default https://tokenharbor.ai)
    ZIM_CLAUDE_BIN                claude executable  (default: claude on PATH)
    ZIM_CLAUDE_STATE_DIR          route, key cache and last pick
    ZIM_CLAUDE_NO_UPDATE=1        never auto-update

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

if ($env:ZIM_CLAUDE_BASE_URL) { $BaseUrl = $env:ZIM_CLAUDE_BASE_URL }
else { $BaseUrl = 'https://tokenharbor.ai' }
$BaseUrl = $BaseUrl.TrimEnd('/')

if ($env:ZIM_CLAUDE_STATE_DIR) { $StateDir = $env:ZIM_CLAUDE_STATE_DIR }
else { $StateDir = Join-Path $env:USERPROFILE '.local\share\zim-claude' }

$RouteFile  = Join-Path $StateDir 'route'
$KeyFile    = Join-Path $StateDir 'tokenharbor.key'
$LastModel  = Join-Path $StateDir 'last-model'

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

# --- the console -------------------------------------------------------------

# Prompts need a console. When stdin is redirected (a script, a pipe, CI) there
# is nobody to answer, so a missing answer is a hard error with the fix in it.
function Test-Interactive {
  try { return -not [Console]::IsInputRedirected } catch { return $false }
}

function Read-Answer {
  param([string]$Prompt)
  [Console]::Error.Write($Prompt)
  try { $reply = Read-Host } catch { $reply = '' }
  return "$reply"
}

function Read-Secret {
  param([string]$Prompt)
  [Console]::Error.Write($Prompt)
  $secure = $null
  try { $secure = Read-Host -AsSecureString } catch { $secure = $null }
  if (-not $secure) { return '' }
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) -replace '\s', '') }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# --- the Token Juice notice --------------------------------------------------

# Token Juice's unlimited quota ended and the route is gone from this package.
# One line on stderr, every run, until the user has a key of their own.
$ApiKey = ''
if ($env:ZIM_CLAUDE_API_KEY) { $ApiKey = ($env:ZIM_CLAUDE_API_KEY -replace '\s', '') }
elseif ($env:TOKENHARBOR_API_KEY) { $ApiKey = ($env:TOKENHARBOR_API_KEY -replace '\s', '') }
$keyFromEnv = -not [string]::IsNullOrEmpty($ApiKey)

if (-not $keyFromEnv -and (Test-Path -LiteralPath $KeyFile)) {
  $cached = (Get-Content -LiteralPath $KeyFile -Raw -ErrorAction SilentlyContinue)
  if ($cached) { $ApiKey = ($cached -replace '\s', '') }
}

if ([string]::IsNullOrEmpty($ApiKey)) {
  Write-Warn "Token Juice is currently down - its unlimited quota ended."
}

# A tj_ key cannot work here any more, and silently sending it to TokenHarbor
# would read as "your key is broken". Name the real reason.
if ($ApiKey -like 'tj_*') {
  Write-Die "that is a Token Juice key (tj_...), and Token Juice is down:
       its unlimited quota ended, and zim-claude no longer runs against it.
       Create a TokenHarbor key at https://tokenharbor.ai/dashboard/api-keys."
}

# The same rule for the base URL: pointing zim-claude back at Token Juice is
# not a supported configuration, so refuse instead of running a dead route.
if ($env:ZIM_CLAUDE_BASE_URL -and $env:ZIM_CLAUDE_BASE_URL -like '*tokenjuice*') {
  Write-Die "ZIM_CLAUDE_BASE_URL names Token Juice, which is down.
       Its unlimited quota ended and zim-claude no longer runs against it.
       Clear ZIM_CLAUDE_BASE_URL to use TokenHarbor."
}

# --- the TokenHarbor opt-in --------------------------------------------------

function Save-Route {
  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  }
  Set-Content -LiteralPath $RouteFile -Value 'tokenharbor' -Encoding ASCII
}

function Test-RouteChosen {
  if (-not (Test-Path -LiteralPath $RouteFile)) { return $false }
  $saved = (Get-Content -LiteralPath $RouteFile -Raw -ErrorAction SilentlyContinue)
  if (-not $saved) { return $false }
  return (($saved -replace '\s', '') -eq 'tokenharbor')
}

$optIn = $env:ZIM_CLAUDE_USE_TOKENHARBOR
if ($optIn -eq '0') {
  Write-Die "Token Juice is down (unlimited quota ended) and TokenHarbor is switched off.
       Clear ZIM_CLAUDE_USE_TOKENHARBOR, or set it to 1, to run against TokenHarbor."
} elseif ($optIn -eq '1') {
  Save-Route
} elseif (-not (Test-RouteChosen)) {
  if (Test-Interactive) {
    $answer = Read-Answer "`n[zim-claude] Token Juice is down. Use TokenHarbor instead?`n  [y/N] "
    if ($answer -match '^\s*(y|yes)\s*$') {
      Save-Route
    } else {
      Write-Die "nothing to run against: Token Juice is down (unlimited quota ended)
       and TokenHarbor was declined. Set ZIM_CLAUDE_USE_TOKENHARBOR=1 to use it."
    }
  } else {
    Write-Die "Token Juice is down (unlimited quota ended) and there is no console
       to ask on. Set ZIM_CLAUDE_USE_TOKENHARBOR=1 to run against TokenHarbor."
  }
}

# --- talking to TokenHarbor --------------------------------------------------

$script:HttpCode = 0
$script:HttpBody = ''

function Invoke-Api {
  param([string]$Path)
  $script:HttpCode = 0
  $script:HttpBody = ''
  try {
    $r = Invoke-WebRequest -Uri "$BaseUrl$Path" -UseBasicParsing -TimeoutSec 20 `
           -Headers @{ Authorization = "Bearer $ApiKey"; Accept = 'application/json' } `
           -ErrorAction Stop
    $script:HttpCode = [int]$r.StatusCode
    $script:HttpBody = [string]$r.Content
  } catch {
    $resp = $null
    try { $resp = $_.Exception.Response } catch { $resp = $null }
    if ($resp) {
      try { $script:HttpCode = [int]$resp.StatusCode } catch { $script:HttpCode = 0 }
      try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $script:HttpBody = $reader.ReadToEnd()
        $reader.Close()
      } catch { $script:HttpBody = '' }
    }
  }
}

# Pull `"id":"..."` out of the models payload. Regex only - the shape here is
# one flat list, and this must work on PowerShell 5.1 with no modules.
function Get-ModelIds {
  param([string]$Json)
  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($m in [regex]::Matches($Json, '"id"\s*:\s*"([^"]+)"')) {
    $ids.Add($m.Groups[1].Value)
  }
  return $ids
}

function Test-FreeModel {
  param([string]$Id)
  return ($Id -like '*:free' -or $Id -eq 'th-rudder')
}

function Get-ModelLabel {
  param([string]$Id)
  switch ($Id) {
    'deepseek-v4.1-flash:free' { return 'DeepSeek V4.1 Flash' }
    'deepseek-v4-flash:free'   { return 'DeepSeek V4 Flash' }
    'mimo-v2.6-flash:free'     { return 'MiMo V2.6 Flash' }
    'mimo-v2.5:free'           { return 'MiMo V2.5' }
    'th-rudder'                { return 'TH-Rudder' }
    default                    { return '' }
  }
}

# --- validate the key and fetch the catalog ----------------------------------

$prevBaseUrl = [Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')
$attempt = 0

while ($true) {
  if ([string]::IsNullOrEmpty($ApiKey)) {
    if (-not (Test-Interactive)) {
      Write-Die "a TokenHarbor API key is required.
       Get one at https://tokenharbor.ai/dashboard/api-keys, then either
       paste it when prompted, or set ZIM_CLAUDE_API_KEY and re-run."
    }
    Write-Info "TokenHarbor API key - create one at https://tokenharbor.ai/dashboard/api-keys"
    $ApiKey = Read-Secret '  paste it here (input is hidden): '
    if ([string]::IsNullOrEmpty($ApiKey)) {
      Write-Die "a TokenHarbor API key is required.
       Get one at https://tokenharbor.ai/dashboard/api-keys, then either
       paste it when prompted, or set ZIM_CLAUDE_API_KEY and re-run."
    }
  }

  Invoke-Api -Path '/v1/models'

  if ($script:HttpCode -eq 200) { break }

  if ($script:HttpCode -eq 401 -or $script:HttpCode -eq 403) {
    if ($keyFromEnv) {
      Write-Die "TokenHarbor rejected ZIM_CLAUDE_API_KEY (HTTP $($script:HttpCode)).
       Rotate it at https://tokenharbor.ai/dashboard/api-keys."
    }
    $attempt = $attempt + 1
    Write-Warn "TokenHarbor rejected that key (HTTP $($script:HttpCode))."
    if ($attempt -ge 3) {
      Write-Die "giving up after 3 rejected keys.
       Create or rotate one at https://tokenharbor.ai/dashboard/api-keys."
    }
    Remove-Item -LiteralPath $KeyFile -ErrorAction SilentlyContinue
    $ApiKey = ''
    continue
  }

  if ($script:HttpCode -eq 0) {
    Write-Die "could not reach $BaseUrl.
       Check your connection, or set ZIM_CLAUDE_BASE_URL if the API lives
       somewhere else."
  }

  Write-Die "$BaseUrl/v1/models answered HTTP $($script:HttpCode).
       $($script:HttpBody)"
}

$ids = Get-ModelIds -Json $script:HttpBody
if ($ids.Count -eq 0) {
  Write-Die "$BaseUrl/v1/models returned no model ids for this key.
       $($script:HttpBody)"
}

# Cache the key the user typed, so the prompt is a first-run cost and not a
# per-session tax. A key from the environment is never written to disk.
if (-not $keyFromEnv) {
  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  }
  Set-Content -LiteralPath $KeyFile -Value $ApiKey -Encoding ASCII
  try { icacls $KeyFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null } catch { }
}

# --- the model picker --------------------------------------------------------

$free = @()
foreach ($id in $ids) { if (Test-FreeModel -Id $id) { $free += $id } }
$note = 'free models'
if ($free.Count -eq 0) { $free = @($ids); $note = 'no free model is advertised - all models' }

if ($env:ZIM_CLAUDE_MODEL) {
  $Model = $env:ZIM_CLAUDE_MODEL
} else {
  if (-not (Test-Interactive)) {
    Write-Die "no console to choose a model on.
       Set ZIM_CLAUDE_MODEL=<model-id> to skip the picker."
  }

  # Default to last time's pick when it is still on offer, so pressing Enter
  # repeatedly is stable instead of drifting to whatever sorts first.
  $defaultN = 1
  if (Test-Path -LiteralPath $LastModel) {
    $previous = ((Get-Content -LiteralPath $LastModel -Raw -ErrorAction SilentlyContinue) -replace '\s', '')
    for ($i = 0; $i -lt $free.Count; $i++) {
      if ($free[$i] -eq $previous) { $defaultN = $i + 1 }
    }
  }

  Write-Info "$note on $BaseUrl"
  for ($i = 0; $i -lt $free.Count; $i++) {
    $label = Get-ModelLabel -Id $free[$i]
    if ($label) {
      [Console]::Error.WriteLine(("  {0,2}) {1,-26} {2}" -f ($i + 1), $free[$i], $label))
    } else {
      [Console]::Error.WriteLine(("  {0,2}) {1}" -f ($i + 1), $free[$i]))
    }
  }

  $Model = ''
  while ($true) {
    $reply = Read-Answer ("  select 1-" + $free.Count + " [" + $defaultN + "]: ")
    $reply = "$reply".Trim()
    if ([string]::IsNullOrEmpty($reply)) { $reply = "$defaultN" }
    $n = 0
    if ([int]::TryParse($reply, [ref]$n) -and $n -ge 1 -and $n -le $free.Count) {
      $Model = $free[$n - 1]
      break
    }
    Write-Warn "not a choice: $reply"
  }
}

if (-not (Test-Path -LiteralPath $StateDir)) {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
}
Set-Content -LiteralPath $LastModel -Value $Model -Encoding ASCII

# --- hand off ----------------------------------------------------------------

# Report the override rather than silently changing provider.
if ($prevBaseUrl -and $prevBaseUrl -ne $BaseUrl) {
  if ($prevBaseUrl -like '*tokenjuice*' -or $prevBaseUrl -like '*localhost:4*' -or
      $prevBaseUrl -like '*127.0.0.1:4*') {
    Write-Warn "ignoring inherited ANTHROPIC_BASE_URL=$prevBaseUrl (Token Juice is down)"
  } else {
    Write-Warn "overriding inherited ANTHROPIC_BASE_URL=$prevBaseUrl -> $BaseUrl"
  }
}

Write-Info "model: $Model"

# Process-scoped only: plain `claude` in this shell is untouched.
[Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $BaseUrl, 'Process')
[Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $ApiKey, 'Process')
[Environment]::SetEnvironmentVariable('ANTHROPIC_MODEL', $Model, 'Process')

# Claude Code names its background and /model-picker calls after Anthropic
# tiers. There is no proxy to rewrite those names now, so point every tier at
# the model that was chosen - otherwise `/model sonnet` asks TokenHarbor for
# "claude-sonnet-4-5" and gets a 404.
foreach ($tier in @('ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
                    'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL')) {
  [Environment]::SetEnvironmentVariable($tier, $Model, 'Process')
}

# Load-bearing. Claude Code prefers ANTHROPIC_AUTH_TOKEN and falls back to
# ANTHROPIC_API_KEY on a truthiness test, so an empty string means the auth
# token wins - and it also clears any real ANTHROPIC_API_KEY from the shell.
[Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', '', 'Process')

# --- self-update -------------------------------------------------------------

# Bring the installed package up to date in the background. Detached so it can
# never delay, block or fail this session; the updater rate-limits itself,
# refuses a dirty checkout, and only fast-forwards. This is what carries a
# Token Juice-era install onto this version.
$noUpdate = $env:ZIM_CLAUDE_NO_UPDATE
if ($noUpdate -ne '1') {
  $updater = Join-Path $SelfDir 'zim-claude-update.ps1'
  if (Test-Path -LiteralPath $updater) {
    try {
      Start-Process -FilePath 'powershell' `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updater) `
                    -WindowStyle Hidden | Out-Null
    } catch {
      # An updater that cannot start is not the user's problem; the session
      # is already healthy by this point.
    }
  }
}

# Forward every argument verbatim and pass claude's exit code through untouched.
& $ClaudeBin @ClaudeArgs
exit $LASTEXITCODE
