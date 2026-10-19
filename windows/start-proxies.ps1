<#
.SYNOPSIS
  Manage both LiteLLM proxies used by zim-claude on Windows.

.DESCRIPTION
  Two independent proxies, on their own ports, exactly as on Linux:

    cli      :4001   Claude Code CLI        (zim-claude)
    desktop  :4002   Claude Desktop gateway

  They share one credential profile but nothing else - separate config, log and
  PID file - so restarting one never disturbs the other.

  This is the Windows counterpart of scripts/start-litellm.sh (CLI) and
  claude-desktop-integration/start-desktop-proxy.sh (Desktop), merged into one
  manager because on Windows the two are always installed together.

.PARAMETER Action
  start | stop | restart | status | logs | gateway | help

.PARAMETER Which
  cli | desktop | all   (default: all)

.EXAMPLE
  .\start-proxies.ps1 start
  .\start-proxies.ps1 status -Which desktop
  .\start-proxies.ps1 gateway

.NOTES
  No secrets live in this file. The upstream key is read from the env profile
  at %USERPROFILE%\claude-source\deepseek-claude; the gateway key defaults to
  sk-claude-desktop-local (it is a local-only shared secret, not the upstream
  credential).
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('start', 'stop', 'restart', 'status', 'logs', 'gateway', 'help')]
  [string]$Action = 'start',

  [ValidateSet('cli', 'desktop', 'all')]
  [string]$Which = 'all'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# --- paths -------------------------------------------------------------------
# /tmp does not exist on Windows, so logs and PID files live under the same
# state directory the installer uses, next to its backups/ and installed.json.
$StateDir = Join-Path $env:USERPROFILE '.local\share\zim-claude'
$LogDir   = Join-Path $StateDir 'logs'
$RunDir   = Join-Path $StateDir 'run'

if ($env:LITELLM_ENV_FILE) { $EnvFile = $env:LITELLM_ENV_FILE }
else { $EnvFile = Join-Path $env:USERPROFILE 'claude-source\deepseek-claude' }

if ($env:CLAUDE_DESKTOP_LITELLM_KEY) { $GatewayKey = $env:CLAUDE_DESKTOP_LITELLM_KEY }
else { $GatewayKey = 'sk-claude-desktop-local' }

# Per-proxy definition. Config paths match where the installer puts them, so a
# file the user hand-edits in place is the one actually served.
#
# The CLI port follows the profile: the installer probes for a port whose proxy
# accepts the profile's token and records it in ANTHROPIC_BASE_URL. Defaulting
# to a fixed port here would start a proxy the profile does not use - and on a
# machine where another LiteLLM owns that port, would fail to bind at all.
$CliPort = 4001
if ($env:LITELLM_PORT) {
  $CliPort = [int]$env:LITELLM_PORT
} elseif (Test-Path -LiteralPath $EnvFile) {
  foreach ($line in Get-Content -LiteralPath $EnvFile -ErrorAction SilentlyContinue) {
    if ($line -match '^export\s+ANTHROPIC_BASE_URL=".*:([0-9]+)"') { $CliPort = [int]$Matches[1]; break }
  }
}
$DeskPort = 4002
if ($env:CLAUDE_DESKTOP_PORT) { $DeskPort = [int]$env:CLAUDE_DESKTOP_PORT }

if ($env:LITELLM_CONFIG) { $CliConfig = $env:LITELLM_CONFIG }
else { $CliConfig = Join-Path $env:USERPROFILE 'litellm-config.yaml' }

if ($env:CLAUDE_DESKTOP_CONFIG) { $DeskConfig = $env:CLAUDE_DESKTOP_CONFIG }
else { $DeskConfig = Join-Path $StateDir 'desktop\litellm-config.desktop.yaml' }

$Proxies = @{
  cli = @{
    Name            = 'cli'
    Port            = $CliPort
    Config          = $CliConfig
    Log             = Join-Path $LogDir 'cli.log'
    PidFile         = Join-Path $RunDir 'cli.pid'
    NeedsGatewayKey = $false
  }
  desktop = @{
    Name            = 'desktop'
    Port            = $DeskPort
    Config          = $DeskConfig
    Log             = Join-Path $LogDir 'desktop.log'
    PidFile         = Join-Path $RunDir 'desktop.pid'
    NeedsGatewayKey = $true
  }
}

# --- output ------------------------------------------------------------------
# Diagnostics never go to stdout: `zim-claude -p "x" --output-format json` pipes
# output into a JSON parser, so stdout must stay clean. Only 'gateway' writes to
# stdout, because its whole purpose is to be pasted into the app.
function Write-Log { param([string]$m) [Console]::Error.WriteLine("[proxy] $m") }
function Write-Err { param([string]$m) [Console]::Error.WriteLine("[proxy] $m") }
function Write-Ok  { param([string]$m) [Console]::Error.WriteLine("[proxy] $m") }

function Get-LiteLLMBin {
  $cmd = Get-Command litellm -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  # pip install --user puts console scripts outside PATH in a per-user Scripts
  # directory; check the documented locations before giving up.
  $candidates = @(
    (Join-Path $env:APPDATA 'Python\Scripts\litellm.exe'),
    (Join-Path $env:USERPROFILE '.local\bin\litellm.exe')
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  $pyRoot = Join-Path $env:APPDATA 'Python'
  if (Test-Path -LiteralPath $pyRoot) {
    $found = Get-ChildItem -Path $pyRoot -Filter 'litellm.exe' -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { return $found.FullName }
  }
  return $null
}

# --- health / process state --------------------------------------------------

function Test-PortAnswers {
  param([int]$Port)
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health/liveliness" `
                           -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

function Get-ProxyPid {
  param($Proxy)
  if (-not (Test-Path -LiteralPath $Proxy.PidFile)) { return $null }
  $raw = Get-Content -LiteralPath $Proxy.PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $raw) { return $null }
  $pidValue = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$pidValue)) { return $null }
  return $pidValue
}

function Test-ProxyRunning {
  param($Proxy)
  $p = Get-ProxyPid -Proxy $Proxy
  if (-not $p) { return $false }
  return [bool](Get-Process -Id $p -ErrorAction SilentlyContinue)
}

# --- profile / config validation ---------------------------------------------

# The env file uses POSIX `export NAME="value"` syntax, kept identical to the
# Linux profile so one file works on both platforms (and in Git Bash).
function Import-Profile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "env file not found: $Path  (run windows\win-install.bat first)"
  }
  $vars = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?(.*?)"?\s*$') {
      $vars[$Matches[1]] = $Matches[2]
    }
  }
  return $vars
}

# Every os.environ/<VAR> the config references must be set, or litellm starts
# and fails later with an opaque auth error. Checking up front names the missing
# variable while it is still actionable.
function Assert-ConfigEnv {
  param($Proxy, $ProfileVars)
  $text = Get-Content -LiteralPath $Proxy.Config -Raw
  $missing = @()
  foreach ($m in [regex]::Matches($text, 'os\.environ/([A-Za-z_][A-Za-z0-9_]*)')) {
    $name = $m.Groups[1].Value
    if ($name -eq 'CLAUDE_DESKTOP_LITELLM_KEY') { continue }   # supplied from $GatewayKey
    if (-not $ProfileVars.ContainsKey($name) -or [string]::IsNullOrEmpty($ProfileVars[$name])) {
      $missing += $name
    }
  }
  if ($missing.Count -gt 0) {
    throw ("config $($Proxy.Config) references unset variable(s): " +
           (($missing | Sort-Object -Unique) -join ', '))
  }
}

# --- actions -----------------------------------------------------------------

function Start-OneProxy {
  param($Proxy)

  if (Test-ProxyRunning -Proxy $Proxy) {
    Write-Log "$($Proxy.Name): already running (pid $(Get-ProxyPid -Proxy $Proxy)) on :$($Proxy.Port)."
    return $true
  }
  if (Test-PortAnswers -Port $Proxy.Port) {
    Write-Err "$($Proxy.Name): port :$($Proxy.Port) is answering but no PID file exists."
    Write-Err "         Run 'start-proxies.ps1 restart' (or stop the stray process) first."
    return $false
  }

  $bin = Get-LiteLLMBin
  if (-not $bin) { Write-Err "$($Proxy.Name): litellm not found. Run windows\win-install.bat."; return $false }
  if (-not (Test-Path -LiteralPath $Proxy.Config)) {
    Write-Err "$($Proxy.Name): config not found: $($Proxy.Config)"; return $false
  }

  $profileVars = Import-Profile -Path $EnvFile
  try { Assert-ConfigEnv -Proxy $Proxy -ProfileVars $profileVars }
  catch { Write-Err "$($Proxy.Name): $_"; return $false }

  # Build the child environment explicitly rather than mutating ours: two
  # proxies run from one process and must not see each other's variables.
  $childEnv = @{}
  foreach ($k in $profileVars.Keys) { $childEnv[$k] = $profileVars[$k] }
  if ($Proxy.NeedsGatewayKey) { $childEnv['CLAUDE_DESKTOP_LITELLM_KEY'] = $GatewayKey }

  New-Item -ItemType Directory -Force -Path $LogDir, $RunDir | Out-Null

  Write-Log "$($Proxy.Name): starting on :$($Proxy.Port)  (config: $($Proxy.Config))"
  Write-Log "$($Proxy.Name): log: $($Proxy.Log)"

  # Start-Process has no -Environment before PowerShell 7.4, so the child
  # inherits this process's environment. Save/restore keeps that mutation
  # contained and makes the two-proxy case correct.
  $saved = @{}
  foreach ($k in $childEnv.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
    [Environment]::SetEnvironmentVariable($k, $childEnv[$k], 'Process')
  }

  $errLog = Join-Path $LogDir "$($Proxy.Name).err.log"
  try {
    $proc = Start-Process -FilePath $bin `
                          -ArgumentList @('--config', $Proxy.Config, '--port', "$($Proxy.Port)") `
                          -WindowStyle Hidden -PassThru `
                          -RedirectStandardOutput $Proxy.Log `
                          -RedirectStandardError $errLog
    Set-Content -LiteralPath $Proxy.PidFile -Value $proc.Id -NoNewline
  } finally {
    foreach ($k in $saved.Keys) {
      [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process')
    }
  }

  # Poll for health - litellm takes several seconds to import and bind. 30s
  # matches the bash manager's budget.
  for ($i = 1; $i -le 30; $i++) {
    if (Test-PortAnswers -Port $Proxy.Port) {
      Write-Ok "$($Proxy.Name): up and healthy (pid $($proc.Id)) on :$($Proxy.Port)."
      return $true
    }
    Start-Sleep -Seconds 1
  }

  Write-Err "$($Proxy.Name): did not become healthy within 30s - last log lines:"
  foreach ($f in @($Proxy.Log, $errLog)) {
    if (Test-Path -LiteralPath $f) {
      Get-Content -LiteralPath $f -Tail 20 | ForEach-Object { [Console]::Error.WriteLine("    $_") }
    }
  }
  return $false
}

function Stop-OneProxy {
  param($Proxy)

  if (Test-ProxyRunning -Proxy $Proxy) {
    $p = Get-ProxyPid -Proxy $Proxy
    Write-Log "$($Proxy.Name): stopping (pid $p)..."
    Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Proxy.PidFile -Force -ErrorAction SilentlyContinue
    Write-Log "$($Proxy.Name): stopped."
    return
  }

  Remove-Item -LiteralPath $Proxy.PidFile -Force -ErrorAction SilentlyContinue
  if (Test-PortAnswers -Port $Proxy.Port) {
    Write-Log "$($Proxy.Name): no PID file, but :$($Proxy.Port) still answers - leaving it alone."
    Write-Log "         (stop the process manually if it is a stray litellm)"
  } else {
    Write-Log "$($Proxy.Name): not running."
  }
}

function Get-OneProxyStatus {
  param($Proxy)
  if (Test-ProxyRunning -Proxy $Proxy) {
    $p = Get-ProxyPid -Proxy $Proxy
    if (Test-PortAnswers -Port $Proxy.Port) { $state = 'healthy' } else { $state = 'NOT answering' }
    Write-Log "$($Proxy.Name): running (pid $p) on :$($Proxy.Port) - $state"
  } else {
    Write-Log "$($Proxy.Name): not running (:$($Proxy.Port))"
  }
}

function Show-Gateway {
  # Exactly the values to paste into Claude Desktop's Third-Party Inference UI.
  # This is the one action that writes to stdout, because the point is to copy it.
  Write-Output "Gateway base URL : http://127.0.0.1:$($Proxies.desktop.Port)"
  Write-Output "Gateway API key  : $GatewayKey"
  Write-Output "Auth scheme      : bearer"
}

# --- dispatch ----------------------------------------------------------------

function Get-Targets {
  if ($Which -eq 'all') { return @($Proxies.cli, $Proxies.desktop) }
  return @($Proxies[$Which])
}

switch ($Action) {
  'help' {
    Get-Help $PSCommandPath -Detailed
  }
  'start' {
    $ok = $true
    foreach ($p in Get-Targets) { if (-not (Start-OneProxy -Proxy $p)) { $ok = $false } }
    if (-not $ok) { exit 1 }
  }
  'stop' {
    foreach ($p in Get-Targets) { Stop-OneProxy -Proxy $p }
  }
  'restart' {
    foreach ($p in Get-Targets) { Stop-OneProxy -Proxy $p }
    $ok = $true
    foreach ($p in Get-Targets) { if (-not (Start-OneProxy -Proxy $p)) { $ok = $false } }
    if (-not $ok) { exit 1 }
  }
  'status' {
    foreach ($p in Get-Targets) { Get-OneProxyStatus -Proxy $p }
  }
  'logs' {
    $files = @()
    foreach ($p in Get-Targets) { if (Test-Path -LiteralPath $p.Log) { $files += $p.Log } }
    if ($files.Count -eq 0) { Write-Err "no log files yet - start a proxy first."; exit 1 }
    Get-Content -LiteralPath $files -Tail 50 -Wait
  }
  'gateway' {
    Show-Gateway
  }
}
