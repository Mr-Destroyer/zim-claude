<#
.SYNOPSIS
  Run Claude Code against Numes on Windows.

.DESCRIPTION
  Windows counterpart of scripts/zim-claude. Every argument is forwarded
  verbatim to claude.exe. This script deliberately parses NO options of its own:
  `zim-claude --help`, `zim-claude mcp list`, `zim-claude -p "..."` and every
  other Claude Code flag/subcommand must reach claude unchanged. Configure it
  through environment variables only. The one argument it adds is --settings,
  described under "the model picker inside Claude Code" below, and it is
  skipped entirely if you pass your own.

  Numes (https://numes.ai) speaks the OpenAI Chat Completions API. Claude Code
  speaks the Anthropic Messages API, so this wrapper starts the bundled Python
  translation proxy (zim-claude-numes-proxy.py), points Claude Code at it for
  this session, and stops it when claude exits. A run:

    1. takes a Numes key from the environment, the state dir, or a prompt
    2. validates it against GET /key and reads the remaining budget
    3. fetches the tool-capable catalog from GET /models
    4. lets the user pick a model, showing each model's price (free first)
    5. writes a session settings file so /model lists every Numes model
    6. starts the translation proxy on a free loopback port
    7. sets ANTHROPIC_* for this process only, runs claude, stops the proxy

    ZIM_CLAUDE_API_KEY            key to use; skips the prompt and the cache
                                  (NUMES_API_KEY is accepted too)
    ZIM_CLAUDE_MODEL              model id to use; skips the picker
    ZIM_CLAUDE_BASE_URL           API root (default https://api.numes.ai/api/v1)
    ZIM_CLAUDE_BIN                claude executable  (default: claude on PATH)
    ZIM_CLAUDE_STATE_DIR          key cache, last pick and the settings file
    ZIM_CLAUDE_NO_UPDATE=1        never auto-update
    ZIM_CLAUDE_NO_PICKER=1        do not add Numes models to /model
    ZIM_CLAUDE_FREE_ONLY=1        only offer models priced $0 in and $0 out
    ZIM_CLAUDE_PROXY_URL          use an existing translation proxy instead of
                                  starting the bundled one
    ZIM_CLAUDE_PYTHON             python interpreter for the proxy

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

# Numes' API root. The chat route is /chat/completions; key and catalog live
# beside it at /key and /models.
if ($env:ZIM_CLAUDE_BASE_URL) { $BaseUrl = $env:ZIM_CLAUDE_BASE_URL }
else { $BaseUrl = 'https://api.numes.ai/api/v1' }
$BaseUrl = $BaseUrl.TrimEnd('/')

if ($env:ZIM_CLAUDE_STATE_DIR) { $StateDir = $env:ZIM_CLAUDE_STATE_DIR }
else { $StateDir = Join-Path $env:USERPROFILE '.local\share\zim-claude' }

$KeyFile      = Join-Path $StateDir 'numes.key'
$LastModel    = Join-Path $StateDir 'last-model'
$SettingsFile = Join-Path $StateDir 'claude-settings.json'
$ProxyScript  = Join-Path $SelfDir 'zim-claude-numes-proxy.py'
if (-not (Test-Path -LiteralPath $ProxyScript)) {
  # Running from a checkout rather than an install: the proxy lives in
  # scripts/, one level above windows/.
  $repoProxy = Join-Path (Split-Path -Parent $SelfDir) 'scripts\zim-claude-numes-proxy'
  if (Test-Path -LiteralPath $repoProxy) { $ProxyScript = $repoProxy }
}
if ($env:ZIM_CLAUDE_PROXY_BIN) { $ProxyScript = $env:ZIM_CLAUDE_PROXY_BIN }

# The model a fresh install starts on: free, tool-capable, 1M context.
$DefaultModel = 'deepseek/deepseek-v4.1-flash'

# All diagnostics go to stderr: `zim-claude -p "x" --output-format json |
# ConvertFrom-Json` must stay parseable, so nothing here may write to stdout.
function Write-Die  { param([string]$m) [Console]::Error.WriteLine("[zim-claude] $m"); exit 2 }
function Write-Warn { param([string]$m) [Console]::Error.WriteLine("[zim-claude] $m") }
function Write-Info { param([string]$m) [Console]::Error.WriteLine("[zim-claude] $m") }

function Get-Prop {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -ne $prop) { return $prop.Value }
  return $null
}

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

# --- python ------------------------------------------------------------------

# The translation proxy is Python. Numes has no Anthropic Messages route, so
# without Python this CLI cannot run; the installer treats it as a prerequisite.
function Get-PythonCmd {
  foreach ($name in @('python', 'python3', 'py')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    $prefix = @()
    if ($name -eq 'py') { $prefix = @('-3') }
    try {
      $checkArgs = @($prefix) + @('-c', 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)')
      & $cmd.Source @checkArgs 2>$null
      if ($LASTEXITCODE -eq 0) {
        return [pscustomobject]@{ Path = $cmd.Source; Prefix = $prefix }
      }
    } catch { continue }
  }
  return $null
}

# --- the API key -------------------------------------------------------------

$ApiKey = ''
if ($env:ZIM_CLAUDE_API_KEY) { $ApiKey = ($env:ZIM_CLAUDE_API_KEY -replace '\s', '') }
elseif ($env:NUMES_API_KEY) { $ApiKey = ($env:NUMES_API_KEY -replace '\s', '') }
$keyFromEnv = -not [string]::IsNullOrEmpty($ApiKey)

if (-not $keyFromEnv -and (Test-Path -LiteralPath $KeyFile)) {
  $cached = (Get-Content -LiteralPath $KeyFile -Raw -ErrorAction SilentlyContinue)
  if ($cached) { $ApiKey = ($cached -replace '\s', '') }
}

# A key from a provider this package no longer routes to cannot work here, and
# sending it to Numes would read as "your key is broken". Name the real reason.
if ($ApiKey -like 'coa_*') {
  Write-Die "that is a Coarena key (coa_...), and this package now routes to Numes.
       Create a Numes key at https://numes.ai/dashboard/keys."
}
if ($ApiKey -like 'tj_*') {
  Write-Die "that is a Token Juice key (tj_...), and this package does not route there.
       Create a Numes key at https://numes.ai/dashboard/keys."
}
if ($ApiKey -like 'thk_*') {
  Write-Die "that is a TokenHarbor key (thk_...), and this package now routes to Numes.
       Create a Numes key at https://numes.ai/dashboard/keys."
}

# The same rule for the API root: pointing zim-claude at a provider this
# package no longer supports is not a configuration worth running.
if ($env:ZIM_CLAUDE_BASE_URL -and
    ($env:ZIM_CLAUDE_BASE_URL -like '*coarena*' -or
     $env:ZIM_CLAUDE_BASE_URL -like '*tokenjuice*' -or
     $env:ZIM_CLAUDE_BASE_URL -like '*tokenharbor*')) {
  Write-Die "ZIM_CLAUDE_BASE_URL names a provider this package no longer routes to.
       Clear ZIM_CLAUDE_BASE_URL to use Numes (https://api.numes.ai/api/v1)."
}

# --- talking to Numes --------------------------------------------------------

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

function Convert-Number {
  param($Value)
  if ($null -eq $Value) { return $null }
  try { return [double]$Value } catch { return $null }
}

function Format-Money {
  param($Value, [string]$Currency)
  $number = Convert-Number $Value
  if ($null -eq $number) { return '' }
  if ($Currency -eq 'BTC') { return ('{0:g} sats' -f $number) }
  return ('${0:0.00}' -f $number)
}

function Get-BudgetLine {
  param([string]$Json)
  if ([string]::IsNullOrEmpty($Json)) { return '' }
  try { $obj = $Json | ConvertFrom-Json } catch { return '' }
  $d = Get-Prop $obj 'data'
  if ($null -eq $d) { return '' }
  $currency = Get-Prop $d 'billing_currency'
  if (-not $currency) { $currency = 'USD' }
  if ((Get-Prop $d 'disabled') -eq $true) { return 'key disabled' }
  $limit = Get-Prop $d 'limit'
  $remaining = Get-Prop $d 'limit_remaining'
  $usage = Get-Prop $d 'usage'
  if ($null -ne $limit -and $null -ne $remaining) {
    return ((Format-Money $remaining $currency) + ' of ' +
            (Format-Money $limit $currency) + ' left')
  }
  if ($null -ne $usage) {
    return ((Format-Money $usage $currency) + ' used')
  }
  return ''
}

function Get-PriceLabel {
  param($Prompt, $Completion)
  $p = Convert-Number $Prompt
  $c = Convert-Number $Completion
  if ($null -eq $p -or $null -eq $c) { return '?' }
  if ($p -eq 0 -and $c -eq 0) { return 'free' }
  return ('${0:0.####}/${1:0.####} per M' -f ($p * 1000000), ($c * 1000000))
}

function Get-CtxLabel {
  param($Context)
  $n = Convert-Number $Context
  if ($null -eq $n -or $n -le 0) { return '?' }
  if ($n -ge 1000000) { return ('{0:0.0}M' -f ($n / 1000000)) }
  if ($n -ge 1000) { return ('{0:0}k' -f ($n / 1000)) }
  return ('{0:0}' -f $n)
}

function Get-Models {
  param([string]$Json)
  if ([string]::IsNullOrEmpty($Json)) { return @() }
  try { $obj = $Json | ConvertFrom-Json } catch { return @() }
  $data = Get-Prop $obj 'data'
  if ($null -eq $data) { return @() }

  $freeOnly = $env:ZIM_CLAUDE_FREE_ONLY -eq '1'
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($m in $data) {
    $id = [string](Get-Prop $m 'id')
    if ([string]::IsNullOrEmpty($id)) { continue }
    $name = [string](Get-Prop $m 'name')
    if ([string]::IsNullOrEmpty($name)) { $name = $id }
    $ctx = Get-Prop $m 'context_length'
    $maxOut = Get-Prop $m 'maximum_output_length'
    if (-not $maxOut) { $maxOut = Get-Prop $m 'maximum_output_tokens' }
    $pricing = Get-Prop $m 'pricing'
    $prompt = Get-Prop $pricing 'prompt'
    $completion = Get-Prop $pricing 'completion'
    $p = Convert-Number $prompt
    $c = Convert-Number $completion
    $total = 999999999
    if ($null -ne $p -and $null -ne $c) { $total = $p + $c }
    if ($freeOnly -and $total -ne 0) { continue }
    $rows.Add([pscustomobject]@{
      Id           = $id
      Name         = $name
      Context      = [string]$ctx
      MaxOutput    = [string]$maxOut
      PriceLabel   = (Get-PriceLabel $prompt $completion)
      CtxLabel     = (Get-CtxLabel $ctx)
      SortPrice    = $total
    })
  }
  return @($rows | Sort-Object SortPrice, Id)
}

# --- validate the key and fetch the catalog ----------------------------------

$prevBaseUrl = [Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'Process')
$attempt = 0
$limitsBody = ''

while ($true) {
  if ([string]::IsNullOrEmpty($ApiKey)) {
    if (-not (Test-Interactive)) {
      Write-Die "a Numes API key is required.
       Get one at https://numes.ai/dashboard/keys, then either paste it when
       prompted, or set NUMES_API_KEY and re-run."
    }
    Write-Info "Numes API key - create one at https://numes.ai/dashboard/keys"
    $ApiKey = Read-Secret '  paste it here (input is hidden): '
    if ([string]::IsNullOrEmpty($ApiKey)) {
      Write-Die "a Numes API key is required.
       Get one at https://numes.ai/dashboard/keys, then either paste it when
       prompted, or set NUMES_API_KEY and re-run."
    }
  }

  # /key is the credential probe and the only budget figure an inference key
  # may read (/credits needs a management key).
  Invoke-Api -Path '/key'

  if ($script:HttpCode -eq 200) { $limitsBody = $script:HttpBody; break }

  if ($script:HttpCode -eq 401 -or $script:HttpCode -eq 403) {
    if ($keyFromEnv) {
      Write-Die "Numes rejected ZIM_CLAUDE_API_KEY (HTTP $($script:HttpCode)).
       Rotate it at https://numes.ai/dashboard/keys."
    }
    $attempt = $attempt + 1
    Write-Warn "Numes rejected that key (HTTP $($script:HttpCode))."
    if ($attempt -ge 3) {
      Write-Die "giving up after 3 rejected keys.
       Create or rotate one at https://numes.ai/dashboard/keys."
    }
    Remove-Item -LiteralPath $KeyFile -ErrorAction SilentlyContinue
    $ApiKey = ''
    continue
  }

  if ($script:HttpCode -eq 402) {
    Write-Die "Numes cannot fund this request: the account is on a funding hold.
       Add credits at https://numes.ai/dashboard/billing, or use a free model."
  }
  if ($script:HttpCode -eq 429) {
    Write-Die "Numes is rate-limiting this key (HTTP 429). Wait a moment and retry."
  }
  if ($script:HttpCode -eq 0) {
    Write-Die "could not reach $BaseUrl.
       Check your connection, or set ZIM_CLAUDE_BASE_URL if the API lives
       somewhere else."
  }

  Write-Die "$BaseUrl/key answered HTTP $($script:HttpCode).
       $($script:HttpBody)"
}

# A disabled key is valid-looking but useless; say so before the picker.
try {
  $keyData = ($limitsBody | ConvertFrom-Json).data
  if ((Get-Prop $keyData 'disabled') -eq $true) {
    Write-Die "this Numes key is disabled.
       Enable or create one at https://numes.ai/dashboard/keys."
  }
} catch { }

# Cache the key the user typed, so the prompt is a first-run cost and not a
# per-session tax. A key from the environment is never written to disk.
if (-not $keyFromEnv) {
  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  }
  Set-Content -LiteralPath $KeyFile -Value $ApiKey -Encoding ASCII
  try { icacls $KeyFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null } catch { }
}

# The catalogue is filtered to text models that call tools. The sort puts the
# genuinely free models first. If the key can see no tool-capable model, retry
# unfiltered and warn rather than showing an empty menu.
Invoke-Api -Path '/models?output_modalities=text&supported_parameters=tools&sort=pricing-low-to-high'
if ($script:HttpCode -eq 0) {
  Write-Die "could not reach $BaseUrl/models.
       Check your connection, or set ZIM_CLAUDE_BASE_URL."
}
if ($script:HttpCode -ne 200) {
  Write-Die "$BaseUrl/models answered HTTP $($script:HttpCode).
       $($script:HttpBody)"
}

$models = @(Get-Models -Json $script:HttpBody)
if ($models.Count -eq 0) {
  Write-Warn "no tool-capable models matched; retrying the catalogue without the tools filter."
  Invoke-Api -Path '/models?output_modalities=text&sort=pricing-low-to-high'
  if ($script:HttpCode -eq 200) {
    $models = @(Get-Models -Json $script:HttpBody)
  }
}
if ($models.Count -eq 0) {
  if ($env:ZIM_CLAUDE_FREE_ONLY -eq '1') {
    Write-Die "no free tool-capable models are listed for this key.
       Unset ZIM_CLAUDE_FREE_ONLY to see the paid catalogue."
  }
  Write-Die "$BaseUrl/models returned no models this key can use.
       $($script:HttpBody)"
}

# --- the model picker --------------------------------------------------------

if ($env:ZIM_CLAUDE_MODEL) {
  $Model = $env:ZIM_CLAUDE_MODEL
  $known = $false
  foreach ($m in $models) { if ($m.Id -eq $Model) { $known = $true } }
  if (-not $known) {
    Write-Warn "$Model is not in the tool-capable catalogue this key can see; using it anyway."
  }
} else {
  if (-not (Test-Interactive)) {
    Write-Die "no console to choose a model on.
       Set ZIM_CLAUDE_MODEL=<model-id> to skip the picker."
  }

  # Default to last time's pick when it is still on offer, so pressing Enter
  # repeatedly is stable instead of drifting to whatever sorts first.
  $defaultN = 1
  $previous = ''
  if (Test-Path -LiteralPath $LastModel) {
    $previous = ((Get-Content -LiteralPath $LastModel -Raw -ErrorAction SilentlyContinue) -replace '\s', '')
  }
  if ([string]::IsNullOrEmpty($previous)) { $previous = $DefaultModel }
  for ($i = 0; $i -lt $models.Count; $i++) {
    if ($models[$i].Id -eq $previous) { $defaultN = $i + 1 }
  }

  $freeCount = 0
  foreach ($m in $models) { if ($m.PriceLabel -eq 'free') { $freeCount = $freeCount + 1 } }

  $budget = Get-BudgetLine -Json $limitsBody
  $summary = "$($models.Count) tool-capable"
  if ($freeCount -gt 0) { $summary = "$summary, $freeCount free" }
  if ($env:ZIM_CLAUDE_FREE_ONLY -eq '1') { $summary = 'free models only' }
  if ($budget) { Write-Info "models on $BaseUrl - $summary - $budget" }
  else { Write-Info "models on $BaseUrl - $summary" }

  for ($i = 0; $i -lt $models.Count; $i++) {
    [Console]::Error.WriteLine(("  {0,2}) {1,-46} {2,-24} {3,-16} {4}" -f
      ($i + 1), $models[$i].Id, $models[$i].Name,
      $models[$i].PriceLabel, $models[$i].CtxLabel))
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
# Numes' ids. The modelPicker settings key lists any id, in any order, under
# any label, with no filter. The file is passed with --settings for this
# session only; nothing is written to the user's own settings.json.
#
# behavesAs is set on every row: even anthropic/claude-* is not an id Claude
# Code's own catalog knows, so without it the unrecognized-model warning and
# the 1M assumption return. It borrows client-side handling without changing
# the id sent to Numes; the real window comes from
# CLAUDE_CODE_AUTO_COMPACT_WINDOW below.
$BehavesAs = 'claude-sonnet-4-5'
$settingsWritten = $false
if ($env:ZIM_CLAUDE_NO_PICKER -ne '1') {
  $options = @()
  foreach ($m in $models) {
    $options += [ordered]@{
      model     = $m.Id
      label     = $m.Name
      behavesAs = $BehavesAs
    }
  }
  if ($options.Count -gt 0) {
    $settings = [ordered]@{
      modelPicker = [ordered]@{
        replaceBuiltInOptions = $true
        options               = $options
      }
    }
    $json = $settings | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($SettingsFile, $json,
      (New-Object System.Text.UTF8Encoding($false)))
    try { icacls $SettingsFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null } catch { }
    $settingsWritten = $true
  }
}

# --- the translation proxy ---------------------------------------------------
#
# Claude Code sends Anthropic Messages; Numes accepts OpenAI Chat Completions.
# The proxy translates both directions, including native tool calls and SSE.
# It listens on loopback only, on a port the OS picks, for this session.

$script:ProxyBase = ''
if ($env:ZIM_CLAUDE_PROXY_URL) { $script:ProxyBase = $env:ZIM_CLAUDE_PROXY_URL.TrimEnd('/') }
$script:proxyProcess = $null
$script:portFile = ''

function Quote-Arg {
  param([string]$Value)
  if ($Value -match '\s') { return '"' + $Value + '"' }
  return $Value
}

function Stop-ProxyProcess {
  if ($null -ne $script:proxyProcess -and -not $script:proxyProcess.HasExited) {
    try { Stop-Process -Id $script:proxyProcess.Id -Force -ErrorAction SilentlyContinue } catch { }
  }
  $script:proxyProcess = $null
}

function Start-TranslationProxy {
  if (-not [string]::IsNullOrEmpty($script:ProxyBase)) { return $true }

  if (-not (Test-Path -LiteralPath $ProxyScript)) {
    Write-Warn "the Numes translation proxy is missing: $ProxyScript"
    Write-Warn "  Re-run win-install.bat."
    return $false
  }

  if ($env:ZIM_CLAUDE_PYTHON) {
    $py = [pscustomobject]@{ Path = $env:ZIM_CLAUDE_PYTHON; Prefix = @() }
  } else {
    $py = Get-PythonCmd
  }
  if (-not $py) {
    Write-Warn "python 3.8+ is required for the Numes translation proxy."
    Write-Warn "  Install Python from https://python.org, then re-run."
    return $false
  }

  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  }

  $script:portFile = Join-Path $StateDir ("numes-port-" + $PID + ".txt")
  Remove-Item -LiteralPath $script:portFile -ErrorAction SilentlyContinue
  $outLog = Join-Path $StateDir ("numes-proxy-" + $PID + ".out.log")
  $errLog = Join-Path $StateDir ("numes-proxy-" + $PID + ".err.log")

  $maxOut = '0'
  foreach ($m in $models) { if ($m.Id -eq $Model -and $m.MaxOutput) { $maxOut = $m.MaxOutput } }

  $pyArgs = @($py.Prefix)
  $pyArgs += @(
    (Quote-Arg $ProxyScript),
    '--port', '0',
    '--port-file', (Quote-Arg $script:portFile),
    '--model', (Quote-Arg $Model),
    '--upstream', (Quote-Arg $BaseUrl),
    '--max-output', $maxOut,
    '--parent-pid', "$PID"
  )

  try {
    $script:proxyProcess = Start-Process -FilePath $py.Path -ArgumentList $pyArgs `
      -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
      -WindowStyle Hidden -PassThru
  } catch {
    Write-Warn "could not start the Numes translation proxy: $_"
    return $false
  }

  for ($i = 0; $i -lt 100; $i++) {
    if (Test-Path -LiteralPath $script:portFile) {
      $text = (Get-Content -LiteralPath $script:portFile -Raw -ErrorAction SilentlyContinue)
      if ($text -and $text.Trim()) { break }
    }
    if ($script:proxyProcess.HasExited) { break }
    Start-Sleep -Milliseconds 100
  }

  $portText = ''
  if (Test-Path -LiteralPath $script:portFile) {
    $portText = ((Get-Content -LiteralPath $script:portFile -Raw -ErrorAction SilentlyContinue) -replace '\s', '')
  }
  if (-not ($portText -match '^[0-9]+$')) {
    Write-Warn "the Numes translation proxy did not start."
    foreach ($log in @($errLog, $outLog)) {
      if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Tail 20 -ErrorAction SilentlyContinue |
          ForEach-Object { [Console]::Error.WriteLine($_) }
      }
    }
    Stop-ProxyProcess
    return $false
  }

  $script:ProxyBase = "http://127.0.0.1:$portText"
  try {
    Invoke-WebRequest -Uri "$($script:ProxyBase)/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
  } catch {
    Write-Warn "the Numes translation proxy failed its health check."
    Stop-ProxyProcess
    return $false
  }
  return $true
}

$proxyStarted = Start-TranslationProxy
if (-not $proxyStarted) {
  Write-Die "cannot start the Numes translation proxy."
}

# --- hand off ----------------------------------------------------------------

# Report the override rather than silently changing provider.
if ($prevBaseUrl -and $prevBaseUrl -ne $script:ProxyBase) {
  if ($prevBaseUrl -like '*coarena*' -or $prevBaseUrl -like '*tokenjuice*' -or
      $prevBaseUrl -like '*tokenharbor*' -or $prevBaseUrl -like '*localhost:4*' -or
      $prevBaseUrl -like '*127.0.0.1:4*') {
    Write-Warn "ignoring inherited ANTHROPIC_BASE_URL=$prevBaseUrl"
  } else {
    Write-Warn "overriding inherited ANTHROPIC_BASE_URL=$prevBaseUrl -> $($script:ProxyBase)"
  }
}

Write-Info "model: $Model"

# Process-scoped only: plain `claude` in this window is untouched.
[Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $script:ProxyBase, 'Process')
[Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $ApiKey, 'Process')
[Environment]::SetEnvironmentVariable('ANTHROPIC_MODEL', $Model, 'Process')

# Claude Code names its background and /model-picker calls after Anthropic
# tiers. There is no reason to let those names reach Numes, which has no such
# ids, so point every tier at the model that was chosen.
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
# Claude Code has no catalog entry for a Numes id, so it assumes a 1M-token
# window. Several catalogue models are 128k or 200k. Left alone, auto-compact
# would wait for 1M tokens of history and the request would 400 on length long
# before that. The number comes from the catalog's own context_length.
$ctx = ''
foreach ($m in $models) { if ($m.Id -eq $Model) { $ctx = $m.Context } }
if (-not [string]::IsNullOrEmpty($ctx)) {
  # Claude Code caps the window it accepts at 1,000,000 and warns above it.
  $n = Convert-Number $ctx
  if ($null -ne $n -and $n -gt 1000000) { $ctx = '1000000' }
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
  Write-Warn "your --settings wins; Numes models will not be added to /model"
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

# Run claude in the foreground, then stop the proxy on every exit path. A
# try/finally rather than a job keeps the console handle with claude.
$status = 1
try {
  & $ClaudeBin @forward
  $status = $LASTEXITCODE
} finally {
  Stop-ProxyProcess
  if ($script:portFile) { Remove-Item -LiteralPath $script:portFile -ErrorAction SilentlyContinue }
}
exit $status
