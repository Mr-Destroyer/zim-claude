<#
.SYNOPSIS
  Run Claude Code against Coarena on Windows.

.DESCRIPTION
  Windows counterpart of scripts/zim-claude. Every argument is forwarded
  verbatim to claude.exe. This script deliberately parses NO options of its own:
  `zim-claude --help`, `zim-claude mcp list`, `zim-claude -p "..."` and every
  other Claude Code flag/subcommand must reach claude unchanged. Configure it
  through environment variables only. The one argument it adds is --settings,
  described under "the model picker inside Claude Code" below, and it is
  skipped entirely if you pass your own.

  Coarena (https://coarena.ai) serves the Anthropic Messages API natively, so
  there is no proxy in the path. A run:

    1. takes a Coarena key from the environment, the state dir, or a prompt
    2. validates it against GET /v1/limits (401 without a key, 200 with one)
    3. fetches the public catalog from GET /v1/models
    4. lets the user pick a model, defaulting to DeepSeek V4.1 Flash
    5. writes a session settings file so /model lists every Coarena model
    6. sets ANTHROPIC_* for this process only, then runs claude

    ZIM_CLAUDE_API_KEY            key to use; skips the prompt and the cache
                                  (COARENA_API_KEY is accepted too)
    ZIM_CLAUDE_MODEL              model id to use; skips the picker
    ZIM_CLAUDE_BASE_URL           API base URL  (default https://coarena.ai/api)
    ZIM_CLAUDE_BIN                claude executable  (default: claude on PATH)
    ZIM_CLAUDE_STATE_DIR          key cache, last pick and the settings file
    ZIM_CLAUDE_NO_UPDATE=1        never auto-update
    ZIM_CLAUDE_NO_PICKER=1        do not add Coarena models to /model

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

# The Messages root, NOT /api/v1. The Anthropic SDK appends /v1/messages to
# whatever base it is handed, so this composes to /api/v1/messages. Handing it
# /api/v1 would compose to /api/v1/v1/messages and 404 on every turn while the
# catalog still worked - the provider's own docs name this exact base.
if ($env:ZIM_CLAUDE_BASE_URL) { $BaseUrl = $env:ZIM_CLAUDE_BASE_URL }
else { $BaseUrl = 'https://coarena.ai/api' }
$BaseUrl = $BaseUrl.TrimEnd('/')

if ($env:ZIM_CLAUDE_STATE_DIR) { $StateDir = $env:ZIM_CLAUDE_STATE_DIR }
else { $StateDir = Join-Path $env:USERPROFILE '.local\share\zim-claude' }

$KeyFile      = Join-Path $StateDir 'coarena.key'
$LastModel    = Join-Path $StateDir 'last-model'
$SettingsFile = Join-Path $StateDir 'claude-settings.json'

# The model a fresh install starts on. DeepSeek V4.1 Flash is the fastest
# tool-capable entry in the catalog and the one this package defaults to.
# Every model on Coarena is priced at 0 in and 0 out, so this is a speed
# choice, not a cost one - see the budget line the picker prints.
$DefaultModel = 'deepseek-v4-1-flash-1017'

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

# --- the API key -------------------------------------------------------------

$ApiKey = ''
if ($env:ZIM_CLAUDE_API_KEY) { $ApiKey = ($env:ZIM_CLAUDE_API_KEY -replace '\s', '') }
elseif ($env:COARENA_API_KEY) { $ApiKey = ($env:COARENA_API_KEY -replace '\s', '') }
$keyFromEnv = -not [string]::IsNullOrEmpty($ApiKey)

if (-not $keyFromEnv -and (Test-Path -LiteralPath $KeyFile)) {
  $cached = (Get-Content -LiteralPath $KeyFile -Raw -ErrorAction SilentlyContinue)
  if ($cached) { $ApiKey = ($cached -replace '\s', '') }
}

# A key from a provider this package no longer routes to cannot work here, and
# silently sending it to Coarena would read as "your key is broken". Name the
# real reason.
if ($ApiKey -like 'tj_*') {
  Write-Die "that is a Token Juice key (tj_...), and this package no longer routes there.
       Create a Coarena key at https://coarena.ai/account/api."
}
if ($ApiKey -like 'thk_*') {
  Write-Die "that is a TokenHarbor key (thk_...), and this package now routes to Coarena.
       Create a Coarena key at https://coarena.ai/account/api."
}

# The same rule for the base URL: pointing zim-claude at a provider this
# package no longer supports is not a configuration worth running.
if ($env:ZIM_CLAUDE_BASE_URL -and
    ($env:ZIM_CLAUDE_BASE_URL -like '*tokenjuice*' -or $env:ZIM_CLAUDE_BASE_URL -like '*tokenharbor*')) {
  Write-Die "ZIM_CLAUDE_BASE_URL names a provider this package no longer routes to.
       Clear ZIM_CLAUDE_BASE_URL to use Coarena (https://coarena.ai/api)."
}

# --- talking to Coarena ------------------------------------------------------

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

# `id` and `display_name` per model. Regex only - the shape here is one flat
# list, and this must work on PowerShell 5.1 with no modules. Falls back to the
# bare id when an entry carries no display_name.
function Get-Models {
  param([string]$Json)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($m in [regex]::Matches($Json, '\{[^{}]*"id"\s*:\s*"([^"]+)"[^{}]*\}')) {
    $id = $m.Groups[1].Value
    $name = ''
    $nm = [regex]::Match($m.Value, '"display_name"\s*:\s*"([^"]*)"')
    if ($nm.Success) { $name = $nm.Groups[1].Value }
    # The context length is carried because Claude Code has no catalog entry
    # for a non-Anthropic id and therefore assumes a 1M-token window for it.
    # Coarena's models are 128k, so that guess is 8x too generous and
    # auto-compact would fire far too late - the request would 400 on length
    # before compaction ever ran. The wrapper feeds the real number to
    # CLAUDE_CODE_AUTO_COMPACT_WINDOW.
    $ctx = ''
    $cm = [regex]::Match($m.Value, '"context_length"\s*:\s*([0-9]+)')
    if ($cm.Success) { $ctx = $cm.Groups[1].Value }
    $out.Add([pscustomobject]@{ Id = $id; Name = $name; ContextLength = $ctx })
  }
  return $out
}

# The day's remaining allowance, from the /limits payload. Printed beside the
# model list because "free" here means no per-token charge, not no ceiling: the
# account is metered in real dollars against a daily budget. Best-effort.
function Get-BudgetLine {
  param([string]$Json)
  if ([string]::IsNullOrEmpty($Json)) { return '' }
  $left = [regex]::Match($Json, '"left_usd"\s*:\s*([0-9.]+)')
  $cap  = [regex]::Match($Json, '"usd_per_day"\s*:\s*([0-9.]+)')
  if (-not $left.Success -or -not $cap.Success) { return '' }
  return ('$' + $left.Groups[1].Value + ' of $' + $cap.Groups[1].Value + ' left today')
}

# --- validate the key and fetch the catalog ----------------------------------

$prevBaseUrl = [Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')
$attempt = 0
$limitsBody = ''

while ($true) {
  if ([string]::IsNullOrEmpty($ApiKey)) {
    if (-not (Test-Interactive)) {
      Write-Die "a Coarena API key is required.
       Get one at https://coarena.ai/account/api, then either paste it when
       prompted, or set ZIM_CLAUDE_API_KEY and re-run."
    }
    Write-Info "Coarena API key - create one at https://coarena.ai/account/api"
    $ApiKey = Read-Secret '  paste it here (input is hidden): '
    if ([string]::IsNullOrEmpty($ApiKey)) {
      Write-Die "a Coarena API key is required.
       Get one at https://coarena.ai/account/api, then either paste it when
       prompted, or set ZIM_CLAUDE_API_KEY and re-run."
    }
  }

  # /v1/limits is the credential probe: 401 without a key, 200 with one. The
  # catalog at /v1/models answers 200 with no key at all, so it cannot tell a
  # good key from a missing one - probing it would accept any string.
  Invoke-Api -Path '/v1/limits'

  if ($script:HttpCode -eq 200) { $limitsBody = $script:HttpBody; break }

  if ($script:HttpCode -eq 401 -or $script:HttpCode -eq 403) {
    if ($keyFromEnv) {
      Write-Die "Coarena rejected ZIM_CLAUDE_API_KEY (HTTP $($script:HttpCode)).
       Rotate it at https://coarena.ai/account/api."
    }
    $attempt = $attempt + 1
    Write-Warn "Coarena rejected that key (HTTP $($script:HttpCode))."
    if ($attempt -ge 3) {
      Write-Die "giving up after 3 rejected keys.
       Create or rotate one at https://coarena.ai/account/api."
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

  Write-Die "$BaseUrl/v1/limits answered HTTP $($script:HttpCode).
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

# The catalog is public, so this is a second request rather than a reuse of the
# probe above - /limits carries the budget, /models carries the lineup.
Invoke-Api -Path '/v1/models'
if ($script:HttpCode -eq 0) {
  Write-Die "could not reach $BaseUrl/v1/models.
       Check your connection, or set ZIM_CLAUDE_BASE_URL."
}
if ($script:HttpCode -ne 200) {
  Write-Die "$BaseUrl/v1/models answered HTTP $($script:HttpCode).
       $($script:HttpBody)"
}

$models = Get-Models -Json $script:HttpBody
if ($models.Count -eq 0) {
  Write-Die "$BaseUrl/v1/models returned no model ids.
       $($script:HttpBody)"
}

# --- the model picker --------------------------------------------------------

if ($env:ZIM_CLAUDE_MODEL) {
  $Model = $env:ZIM_CLAUDE_MODEL
} else {
  if (-not (Test-Interactive)) {
    Write-Die "no console to choose a model on.
       Set ZIM_CLAUDE_MODEL=<model-id> to skip the picker."
  }

  # Default to last time's pick when it is still on offer, so pressing Enter
  # repeatedly is stable instead of drifting to whatever sorts first. A fresh
  # install starts on $DefaultModel when the catalog still lists it.
  $defaultN = 1
  $previous = ''
  if (Test-Path -LiteralPath $LastModel) {
    $previous = ((Get-Content -LiteralPath $LastModel -Raw -ErrorAction SilentlyContinue) -replace '\s', '')
  }
  if ([string]::IsNullOrEmpty($previous)) { $previous = $DefaultModel }
  for ($i = 0; $i -lt $models.Count; $i++) {
    if ($models[$i].Id -eq $previous) { $defaultN = $i + 1 }
  }

  $budget = Get-BudgetLine -Json $limitsBody
  if ($budget) { Write-Info "models on $BaseUrl - $budget" }
  else { Write-Info "models on $BaseUrl" }

  for ($i = 0; $i -lt $models.Count; $i++) {
    $label = $models[$i].Name
    if ($label) {
      [Console]::Error.WriteLine(("  {0,2}) {1,-26} {2}" -f ($i + 1), $models[$i].Id, $label))
    } else {
      [Console]::Error.WriteLine(("  {0,2}) {1}" -f ($i + 1), $models[$i].Id))
    }
  }

  $Model = ''
  while ($true) {
    $reply = Read-Answer ("  select 1-" + $models.Count + " [" + $defaultN + "]: ")
    $reply = "$reply".Trim()
    if ([string]::IsNullOrEmpty($reply)) { $reply = "$defaultN" }
    $n = 0
    if ([int]::TryParse($reply, [ref]$n) -and $n -ge 1 -and $n -le $models.Count) {
      $Model = $models[$n - 1].Id
      break
    }
    Write-Warn "not a choice: $reply"
  }
}

if (-not (Test-Path -LiteralPath $StateDir)) {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
}
Set-Content -LiteralPath $LastModel -Value $Model -Encoding ASCII

# --- the model picker inside Claude Code -------------------------------------
#
# `/model` lists Claude Code's built-in lineup, which knows nothing about
# Coarena's ids. Two mechanisms can change that:
#
#   * CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 asks Claude Code to read
#     /v1/models itself - but it keeps only ids containing "claude" or
#     "anthropic", so on Coarena it would surface only the Claude ids and hide
#     deepseek, gemini, kimi, grok, qwen, glm, hy4, mimo and minimax.
#   * the `modelPicker` settings key lists any id, in any order, under any
#     label, with no filter at all.
#
# So the wrapper writes a settings file and passes it with --settings, which
# applies to this session only. Nothing is written to the user's own
# settings.json: these models exist only while routed through Coarena, and a
# plain `claude` in another window must not inherit them.
#
# replaceBuiltInOptions is on because the built-in rows (Opus 5.5, Sonnet 5.5,
# ...) are Anthropic-API ids that Coarena does not serve under those names;
# leaving them in the picker would offer rows that 404 on selection.
#
# behavesAs is set on the rows Claude Code does not know - every non-Claude id.
# Without it Claude Code has no catalog entry for the model, so it assumes a
# 1M-token window and prints a warning on every single run:
#
#   Claude Code doesn't recognize the model "deepseek-v4-1-flash-1017", so it
#   assumes a context window of 1m tokens.
#
# behavesAs borrows a known model's client-side handling (prompt profile,
# capability and effort defaults) without changing the id that is sent. It does
# NOT set the window - it inherits the borrowed model's, which is 200k for
# claude-sonnet-4-5 - so the real 128k is applied separately through
# CLAUDE_CODE_AUTO_COMPACT_WINDOW below. The two together are what make a
# Coarena session quiet and correctly bounded; either one alone is not.
#
# Claude ids are left alone: Claude Code already knows them, and overriding
# their handling would be a downgrade.

# The model whose client-side handling a non-Claude Coarena id borrows. Sonnet
# is the closest match for a general tool-calling model, and it is a stable id
# that will not be retired out from under the picker.
$BehavesAs = 'claude-sonnet-4-5'

function ConvertTo-JsonString {
  param([string]$s)
  return ($s -replace '\\', '\\\\' -replace '"', '\"')
}

$settingsWritten = $false
if ($env:ZIM_CLAUDE_NO_PICKER -ne '1') {
  $rows = New-Object System.Collections.Generic.List[string]
  foreach ($m in $models) {
    $label = $m.Name
    if ([string]::IsNullOrEmpty($label)) { $label = $m.Id }
    $row = '    {"model": "' + (ConvertTo-JsonString $m.Id) + '", "label": "' + (ConvertTo-JsonString $label) + '"'
    # Only ids Claude Code does not already know need the borrowed handling.
    if (-not $m.Id.StartsWith('claude-')) {
      $row += ', "behavesAs": "' + (ConvertTo-JsonString $BehavesAs) + '"'
    }
    $row += '}'
    $rows.Add($row)
  }
  if ($rows.Count -gt 0) {
    $json = @(
      '{'
      '  "modelPicker": {'
      '    "replaceBuiltInOptions": true,'
      '    "options": ['
      ($rows -join (',' + [Environment]::NewLine))
      '    ]'
      '  }'
      '}'
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $SettingsFile -Value $json -Encoding ASCII
    try { icacls $SettingsFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null } catch { }
    $settingsWritten = $true
  }
}

# --- hand off ----------------------------------------------------------------

# Report the override rather than silently changing provider.
if ($prevBaseUrl -and $prevBaseUrl -ne $BaseUrl) {
  if ($prevBaseUrl -like '*tokenjuice*' -or $prevBaseUrl -like '*tokenharbor*' -or
      $prevBaseUrl -like '*localhost:4*' -or $prevBaseUrl -like '*127.0.0.1:4*') {
    Write-Warn "ignoring inherited ANTHROPIC_BASE_URL=$prevBaseUrl"
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
# tiers. There is no proxy to rewrite those names, so point every tier at the
# model that was chosen - otherwise `/model sonnet` asks Coarena for
# "claude-sonnet-4-5" and gets a 404.
foreach ($tier in @('ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
                    'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL')) {
  [Environment]::SetEnvironmentVariable($tier, $Model, 'Process')
}

# Load-bearing. Claude Code prefers ANTHROPIC_AUTH_TOKEN and falls back to
# ANTHROPIC_API_KEY on a truthiness test, so an empty string means the auth
# token wins - and it also clears any real ANTHROPIC_API_KEY from the shell.
[Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', '', 'Process')

# --- the context window ------------------------------------------------------
#
# Claude Code has no catalog entry for a non-Anthropic id, so it assumes a
# 1M-token window. Coarena's models are 128k. Left alone, auto-compact would
# wait for 1M tokens of history and the request would 400 on length long before
# that - the session dies instead of compacting.
#
# CLAUDE_CODE_AUTO_COMPACT_WINDOW is the lever that actually moves the window
# Claude Code plans against (CLAUDE_CODE_MAX_CONTEXT_TOKENS only silences the
# warning and leaves the 1M assumption in place). The number comes from the
# catalog's own context_length, so it follows the model rather than being
# hardcoded here.
#
# Only set when the catalog gave us a number: an unset variable is better than
# a wrong one, and Claude Code's own default is right for a Claude id.
$ctx = ''
foreach ($m in $models) { if ($m.Id -eq $Model) { $ctx = $m.ContextLength } }
if (-not [string]::IsNullOrEmpty($ctx)) {
  [Environment]::SetEnvironmentVariable('CLAUDE_CODE_AUTO_COMPACT_WINDOW', $ctx, 'Process')
}

# --- the settings argument ---------------------------------------------------
#
# --settings is the one argument this wrapper adds. It is skipped when the user
# passes their own, because two --settings flags would fight and theirs is the
# one that should win.

$userHasSettings = $false
foreach ($a in $ClaudeArgs) {
  if ($a -eq '--settings' -or $a -like '--settings=*') { $userHasSettings = $true }
}

$forward = @()
if ($userHasSettings) {
  Write-Warn "your --settings wins; Coarena models will not be added to /model"
} elseif ($settingsWritten -and (Test-Path -LiteralPath $SettingsFile)) {
  $forward += @('--settings', $SettingsFile)
}
$forward += $ClaudeArgs

# --- self-update -------------------------------------------------------------

# Bring the installed package up to date in the background. Detached so it can
# never delay, block or fail this session; the updater rate-limits itself,
# refuses a dirty checkout, and only fast-forwards.
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
& $ClaudeBin @forward
exit $LASTEXITCODE
