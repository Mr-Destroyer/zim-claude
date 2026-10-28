<#
.SYNOPSIS
  Install zim-claude and the Claude Desktop gateway on Windows.

.DESCRIPTION
  One installer for both sides, because on Windows they are always wanted
  together:

    CLI      :4001   Claude Code CLI         (the zim-claude command)
    Desktop  :4002   Claude Desktop gateway  (Third-Party Inference)

  It mirrors the behaviour of the two bash installers (install.sh at the repo
  root, and claude-desktop-integration/install.sh) rather than their code:
  dry-run, backups, content-comparison, a state file so uninstall only removes
  what it installed and left unmodified, and a credential that is never
  overwritten.

  Run windows\win-install.bat, which shims to this file.

.PARAMETER SkipCli
  Do not install the CLI side (the CLI proxy).

.PARAMETER SkipDesktop
  Do not install the Claude Desktop side (:4002).

.PARAMETER NoStart
  Install but do not start the proxies.

.PARAMETER Force
  Overwrite files you have hand-edited (a backup is still taken).

.PARAMETER DryRun
  Print every action and change nothing.

.PARAMETER Uninstall
  Remove what this installer created. Your credential is never removed.

.PARAMETER Port
  Use this proxy port instead of probing for one.

.PARAMETER Help
  Show this help.

.EXAMPLE
  .\win-install.bat -DryRun
  .\win-install.bat
  .\win-install.bat -SkipDesktop
  .\win-install.bat -Uninstall
#>

[CmdletBinding()]
param(
  [switch]$SkipCli,
  [switch]$SkipDesktop,
  [switch]$NoStart,
  [switch]$Force,
  [switch]$DryRun,
  [switch]$Uninstall,
  [int]$Port = 0,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# --- where we are ------------------------------------------------------------
# The repo is one level up from windows\. Everything installed is copied out of
# there, so a fresh clone plus this script is all that is needed.
$SrcDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$WinDir = Join-Path $SrcDir 'windows'

# --- output ------------------------------------------------------------------
$script:PrereqFailed = $false

function Write-Say  { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red }

# A dry run reports what is missing but never reports a failed install: nothing
# was attempted, so a non-zero exit would be misleading.
function Set-PrereqFailed {
  if (-not $DryRun) { $script:PrereqFailed = $true }
}

# Every mutation goes through Invoke-Step, so -DryRun is honest.
function Invoke-Step {
  param([string]$Description, [scriptblock]$Action)
  if ($DryRun) {
    Write-Host "    would: $Description"
    return
  }
  & $Action
}

# --- paths -------------------------------------------------------------------
$BinDir    = Join-Path $env:USERPROFILE '.local\bin'
# The model-name config and the credential live together in the Token Juice
# directory, shared with any other harness on this machine.
$TokenJuiceDir = Join-Path $env:USERPROFILE 'tokenjuice'
$EnvFile   = Join-Path $TokenJuiceDir 'source'
$CliConfig = Join-Path $TokenJuiceDir 'litellm-config.yaml'

$StateDir   = Join-Path $env:USERPROFILE '.local\share\zim-claude'
$StateFile  = Join-Path $StateDir 'installed.json'
$BackupRoot = Join-Path $StateDir 'backups'
$Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir  = Join-Path $BackupRoot $Stamp

$DeskConfigDir = $TokenJuiceDir
$DeskConfig    = Join-Path $DeskConfigDir 'litellm-config.desktop.yaml'

$UpdateConf    = Join-Path $StateDir 'update.json'

# The credential and port this install ends up with. Read by the conflict check
# (so it does not warn about values it just wrote) and by the shell-profile
# migration. Set by Install-EnvProfile.
$script:EffectiveToken = ''
$script:EffectivePort  = 4000

# Values printed for the Claude Desktop dialog. The desktop proxy config reads
# the same env var the CLI config does, so one profile serves both and the
# shared secret stays in exactly one place.
#
# Honours CLAUDE_DESKTOP_LITELLM_KEY for the same reason start-proxies.ps1 and
# verify.ps1 do: those two enforce whatever key is in the environment, so a
# hardcoded default here would print the WRONG key for the dialog - the app
# would send it, the proxy would reject it, and LiteLLM reports a key mismatch
# as "No connected db." (it assumes an unmatched key is a DB-backed virtual
# key, and there is no DB).
$DeskProxyPort = 4002
if ($env:CLAUDE_DESKTOP_LITELLM_KEY) { $GatewayKey = $env:CLAUDE_DESKTOP_LITELLM_KEY }
else { $GatewayKey = 'sk-claude-desktop-local' }

# --- helpers -----------------------------------------------------------------

function Get-FileHashString {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Read-State {
  if (-not (Test-Path -LiteralPath $StateFile)) { return @() }
  try {
    # -Encoding UTF8 must match the writer: Set-Content -Encoding UTF8 emits a
    # BOM on 5.1, and reading that back under the ANSI default puts three junk
    # characters in front of the JSON, which ConvertFrom-Json then rejects.
    $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    # Drop anything that is not an entry before returning it. This script runs
    # under Set-StrictMode -Version 2.0, where reading a property that does not
    # exist is a FATAL PropertyNotFoundStrict error rather than $null. So one
    # entry without `path` - a file from an older revision, a hand-edited one,
    # a stray null - aborts the whole install the moment a caller touches
    # .path, which is exactly the failure this guards against. The state file
    # only tells -Uninstall what it may safely delete; nothing in it is worth
    # failing an install over.
    return @(@(ConvertFrom-Json $raw) | Where-Object { $_ -and $_.PSObject.Properties['path'] })
  } catch {
    Write-Warn "state file unreadable, treating as empty: $StateFile"
    return @()
  }
}

function Add-State {
  param([string]$Path, [string]$Hash, [string]$Scope)
  if ($DryRun) { return }
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $entries = @(Read-State)
  $entries += [pscustomobject]@{ path = $Path; sha256 = $Hash; scope = $Scope }
  ($entries | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Test-FileIsOurs {
  param([string]$Path)
  $entry = @(Read-State) | Where-Object { $_.path -eq $Path } | Select-Object -First 1
  if (-not $entry) { return $false }
  return ((Get-FileHashString -Path $Path) -eq $entry.sha256)
}

function Backup-IfExists {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $safe = ($Path -replace '^[A-Za-z]:', '') -replace '[\\/:]', '_'
  $dest = Join-Path $BackupDir $safe
  Write-Say "backing up $Path -> $dest"
  Invoke-Step "mkdir $BackupDir" { New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null }
  Invoke-Step "copy $Path -> $dest" { Copy-Item -LiteralPath $Path -Destination $dest -Force }
}

# Install-File <src> <dest> <scope>
function Install-File {
  param([string]$Src, [string]$Dest, [string]$Scope)

  if (-not (Test-Path -LiteralPath $Src)) {
    Write-Err "missing source file: $Src"
    return $false
  }

  if (Test-Path -LiteralPath $Dest) {
    if ((Get-FileHashString -Path $Src) -eq (Get-FileHashString -Path $Dest)) {
      Write-Say "unchanged: $Dest"
      return $true
    }
    if (-not $Force -and -not (Test-FileIsOurs -Path $Dest)) {
      Write-Warn "you have modified this file - leaving it alone: $Dest"
      Write-Warn "  re-run with -Force to overwrite (a backup is still taken)"
      return $false
    }
  }

  Backup-IfExists -Path $Dest
  Write-Say "installing $Dest"
  Invoke-Step "copy $Src -> $Dest" {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
    Copy-Item -LiteralPath $Src -Destination $Dest -Force
  }
  Add-State -Path $Dest -Hash (Get-FileHashString -Path $Src) -Scope $Scope
  return $true
}

# The env file is special: it holds a live credential, so it is never
# overwritten - not even with -Force. Losing it would mean re-issuing a token.
# --- choosing a proxy port ---------------------------------------------------
#
# Mirrors install.sh. The profile points claude at a local proxy, and a proxy
# that rejects the profile's token looks exactly like a broken install: every
# request answers "No connected db." Another LiteLLM (ZimZilla's, a leftover
# install) holding the default port is the usual cause.

$PortCandidates = @(4000, 4001, 4003, 4004, 4005, 4006, 4007, 4008, 4009, 4010)

# Something is listening on the port. A connection error is the "free" signal.
function Test-PortOpen {
  param([int]$Candidate)
  try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', $Candidate, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(400, $false)
    if ($ok -and $c.Connected) { $c.Close(); return $true }
    $c.Close()
    return $false
  } catch { return $false }
}

# A LiteLLM started with a master key matching the token answers /v1/models
# with 200. A mismatched master key answers 400; an unauthenticated service 401.
function Test-ProxyAcceptsToken {
  param([int]$Candidate, [string]$Token)
  if ([string]::IsNullOrEmpty($Token)) { return $false }
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Candidate/v1/models" `
          -Headers @{ Authorization = "Bearer $Token" } `
          -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

function Get-PortFromUrl {
  param([string]$Url)
  if ($Url -match ':([0-9]+)') { return [int]$Matches[1] }
  return 4000
}

# The profile aims at a proxy on this machine. That is the only kind of profile
# this installer manages; one aimed at a provider directly is the user's own and
# is never rewritten.
function Test-LocalProxyUrl {
  param([string]$Url)
  if ([string]::IsNullOrEmpty($Url)) { return $false }
  return ($Url -match 'localhost:' -or $Url -match '127\.0\.0\.1:')
}

# Returns the port to write into the profile.
function Select-ProxyPort {
  param([string]$Token, [string]$CurrentUrl)

  if ($Port -gt 0) {
    Write-Say "proxy port: $Port (-Port)"
    return $Port
  }

  if (-not [string]::IsNullOrEmpty($CurrentUrl)) {
    $current = Get-PortFromUrl -Url $CurrentUrl
    if (Test-ProxyAcceptsToken -Candidate $current -Token $Token) {
      Write-Say "proxy port: $current (already accepting the profile's token)"
      return $current
    }
    if (-not (Test-PortOpen -Candidate $current)) {
      Write-Say "proxy port: $current (free - zim-claude will start the proxy there)"
      return $current
    }
    Write-Warn "port :$current is taken by something that rejects the profile's token"
  }

  foreach ($p in $PortCandidates) {
    if (Test-ProxyAcceptsToken -Candidate $p -Token $Token) {
      Write-Say "proxy port: $p (a running proxy already accepts the token)"
      return $p
    }
  }
  foreach ($p in $PortCandidates) {
    if (-not (Test-PortOpen -Candidate $p)) {
      Write-Say "proxy port: $p (free)"
      return $p
    }
  }

  Write-Warn "every candidate port is busy and none accepts the token."
  Write-Warn "  falling back to :4000 - pass -Port N to choose another."
  return 4000
}

function Install-EnvProfile {
  Invoke-Step "mkdir $TokenJuiceDir" { New-Item -ItemType Directory -Force -Path $TokenJuiceDir | Out-Null }

  # The key comes from the profile if it has one, or from ZIM_CLAUDE_TOKEN for
  # a scripted install. Nothing is read from this checkout any more: Token
  # Juice's unlimited quota ended, so the key file that ships in it is
  # deliberately not loaded, and a missing key is NOT an error - the wrapper
  # offers TokenHarbor instead. Trims surrounding whitespace, including the CR a
  # browser copy-paste adds - a trailing CR inside the export produces a 401
  # that looks like a bad key.
  $token = ''
  $src = ''
  if ($env:ZIM_CLAUDE_TOKEN) {
    $token = ($env:ZIM_CLAUDE_TOKEN -replace '\s', '')
    $src = 'ZIM_CLAUDE_TOKEN'
  }
  # Deliberately no fallback to the key file that ships in the checkout.

  $port = 0

  if (Test-Path -LiteralPath $EnvFile) {
    # The profile holds a live credential, so it is never overwritten - not even
    # with -Force. The one thing repaired is a base URL naming a port that
    # rejects its own token (another proxy owns it), with a backup.
    $current = ''
    $currentUrl = ''
    foreach ($line in Get-Content -LiteralPath $EnvFile -ErrorAction SilentlyContinue) {
      if ($line -match '^export\s+ANTHROPIC_AUTH_TOKEN="(.*)"$') { $current = $Matches[1] }
      if ($line -match '^export\s+ANTHROPIC_BASE_URL="(.*)"$')  { $currentUrl = $Matches[1] }
    }

    if (-not [string]::IsNullOrEmpty($current)) {
      # Keep the credential; make sure its port works.
      if (-not ($current -like 'tj_*')) {
        Write-Warn "$EnvFile holds a key that does not look like a Token Juice key (tj_...)."
        Write-Warn "  Keeping it: if it belongs to another provider, Token Juice will reject it."
      }
      $port = Select-ProxyPort -Token $current -CurrentUrl $currentUrl
      if ([string]::IsNullOrEmpty($currentUrl) -or ($port -eq (Get-PortFromUrl -Url $currentUrl))) {
        Write-Say "keeping existing env file: $EnvFile (never overwritten)"
        $script:EffectiveToken = $current
        $script:EffectivePort  = $port
        return $true
      }
      Backup-IfExists -Path $EnvFile
      Write-Say "moving the env profile to port :$port (it rejected its token on :$(Get-PortFromUrl -Url $currentUrl))"
      if ($DryRun) {
        Write-Host "    would rewrite ANTHROPIC_BASE_URL to http://localhost:$port"
        return $true
      }
      # Keep the profile's own credential, not the repo's.
      $token = $current
      # Fall through to the writer below.

    } else {
      # The file exists but carries no ANTHROPIC_AUTH_TOKEN. Fall through and
      # write a complete one.
      $port = Select-ProxyPort -Token $token -CurrentUrl $currentUrl
    }
  }

  if ($port -eq 0) { $port = Select-ProxyPort -Token $token }

  if ([string]::IsNullOrEmpty($token)) {
    # No credential anywhere. Not an error any more: Token Juice is down, the
    # wrapper offers TokenHarbor on first run, and anyone who wants the proxy
    # route can set ZIM_CLAUDE_TOKEN=tj_... and re-run. Returning success
    # matters - the background updater runs this with no console to prompt on.
    if ($DryRun) {
      Write-Host "    would skip the credential profile (Token Juice is down)"
      return $true
    }
    Write-Say "no Token Juice key in $EnvFile or ZIM_CLAUDE_TOKEN - skipping the profile"
    Write-Say "  (Token Juice is down; zim-claude will offer TokenHarbor instead)"
    return $true
  }

  if ($token -notmatch '^[A-Za-z0-9_.:-]+$') {
    Write-Err "token in $src contains unexpected characters - refusing to install it"
    return $false
  }

  Write-Say "writing env file: $EnvFile"
  if ($DryRun) {
    Write-Host "    would write 4 ANTHROPIC_* exports (token redacted)"
    return $true
  }

  # Written in POSIX `export` syntax, byte-compatible with the Linux profile so
  # the same file works on both platforms and in Git Bash.
  $content = @(
    "export ANTHROPIC_BASE_URL=`"http://localhost:$port`""
    "export ANTHROPIC_AUTH_TOKEN=`"$token`""
    'export ANTHROPIC_MODEL="deepseek-v4.1-flash-1017"'
    'export ANTHROPIC_API_KEY=""'
  ) -join "`n"
  # Explicit LF, no BOM: a CRLF here would put a CR inside the token.
  [IO.File]::WriteAllText($EnvFile, $content + "`n", (New-Object Text.UTF8Encoding $false))
  Write-Ok "wrote $EnvFile (port $port)"
  $script:EffectiveToken = $token
  $script:EffectivePort  = $port
  return $true
}

function Install-DesktopConfig {
  $src = Join-Path $SrcDir 'claude-desktop-integration\litellm-config.desktop.yaml'
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Err "missing source file: $src"
    return $false
  }

  if (Test-Path -LiteralPath $DeskConfig) {
    # The Token Juice directory is shared with the CLI route and with anything
    # else on this machine using it: an existing config belongs to whoever put
    # it there, so it is used as-is and never rewritten - not even with -Force.
    Write-Say "using the desktop config already in place: $DeskConfig"
    return $true
  }

  Backup-IfExists -Path $DeskConfig
  Write-Say "installing $DeskConfig"
  Invoke-Step "copy $src -> $DeskConfig" {
    New-Item -ItemType Directory -Force -Path $DeskConfigDir | Out-Null
    Copy-Item -LiteralPath $src -Destination $DeskConfig -Force
  }
  Add-State -Path $DeskConfig -Hash (Get-FileHashString -Path $src) -Scope 'desktop'
  return $true
}

# --- auto-update -------------------------------------------------------------

# Record where this checkout lives and which branch it tracks, so the wrapper's
# background updater can fast-forward it. Auto-update is only enabled when the
# source really is a git checkout on a named branch; an unpacked archive has
# nothing to pull from.
#
# Rewritten on every install - unlike the credential profile, this is
# bookkeeping, not user data.
function Write-UpdateConf {
  $repo = ''
  $branch = ''
  $enabled = $false

  if (Test-Path -LiteralPath (Join-Path $SrcDir '.git')) {
    if (Get-Command git -ErrorAction SilentlyContinue) {
      $repo = $SrcDir
      $branch = (& git -C $SrcDir symbolic-ref --quiet --short HEAD 2>$null)
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($branch)) {
        $enabled = $true
      } else {
        $branch = ''
      }
    }
  }

  if ($enabled) {
    Write-Say "auto-update: tracking origin/$branch in $repo"
  } else {
    Write-Say "auto-update: disabled (source is not a git checkout on a branch)"
  }

  Invoke-Step "mkdir $StateDir" { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  if ($DryRun) {
    Write-Host "    would write $UpdateConf (auto-update=$enabled, branch=$branch)"
    return
  }

  $obj = [pscustomobject]@{
    autoUpdate = $enabled
    repoDir    = $repo
    branch     = $branch
  }
  $obj | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $UpdateConf -Encoding UTF8
}

# --- prerequisites -----------------------------------------------------------

function Get-PythonCmd {
  foreach ($name in @('python', 'py')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    try {
      $v = [string](& $cmd.Source -c 'import sys;print(sys.version_info[0],sys.version_info[1])' 2>$null)
      if ($v -match '^3\s+(\d+)') {
        if ([int]$Matches[1] -ge 10) { return $cmd.Source }
      }
    } catch { continue }
  }
  return $null
}

# Prompt only when there is a human to answer. A redirected stdin (CI, piped
# install) would make Read-Host throw, so report the command instead.
function Confirm-Install {
  param([string]$Name, [string]$Command)
  # A dry run must not install anything, so the prompt never appears - the
  # command is printed for the user to run themselves afterwards.
  if ($DryRun) {
    Write-Warn "$Name not found. Would install with:"
    Write-Warn "  $Command"
    return $false
  }
  if ([Console]::IsInputRedirected) {
    Write-Warn "$Name not found. Install with:"
    Write-Warn "  $Command"
    return $false
  }
  Write-Warn "$Name not found. Install now?"
  Write-Host "      $Command"
  $reply = Read-Host "      [y/N]"
  return ($reply -match '^[yY]')
}

function Get-LiteLLMBin {
  $cmd = Get-Command litellm -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
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

function Test-Prereqs {
  # Python is needed for litellm. Checked first because everything else depends
  # on it and the fix is a single winget command.
  $python = Get-PythonCmd
  if ($python) {
    Write-Say "found python: $python"
  } else {
    Write-Warn "python 3.10+ not found (litellm is a Python package)."
    if ((Get-Command winget -ErrorAction SilentlyContinue) -and
        (Confirm-Install 'Python' 'winget install Python.Python.3.12')) {
      Write-Say "running: winget install Python.Python.3.12"
      try { winget install --id Python.Python.3.12 -e --source winget } catch {
        Write-Warn "python install failed - continuing."
      }
      $python = Get-PythonCmd
      if ($python) { Write-Ok "python installed." } else { Set-PrereqFailed }
    } else {
      Write-Warn "install Python 3.10+ from https://python.org, then re-run."
      Set-PrereqFailed
    }
  }

  $litellm = Get-LiteLLMBin
  if ($litellm) {
    Write-Say "found litellm: $litellm"
  } else {
    Write-Warn "litellm not found."
    if ($python -and (Confirm-Install 'litellm' "$python -m pip install --user `"litellm[proxy]`"")) {
      Write-Say "running: $python -m pip install --user `"litellm[proxy]`""
      try {
        & $python -m pip install --user 'litellm[proxy]'
        Write-Ok "litellm installed."
      } catch {
        Write-Warn "litellm install failed - continuing."
        Set-PrereqFailed
      }
    } else {
      Write-Warn "skipped litellm."
      Set-PrereqFailed
    }
  }

  if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Say "found claude: $((Get-Command claude).Source)"
  } else {
    Write-Warn "claude not found on PATH."
    # Anthropic's own native Windows installer. No Node, no admin, no WSL. It
    # installs to %USERPROFILE%\.local\bin and may not refresh this session's
    # PATH, which is why the wrapper also checks that location directly.
    if (Confirm-Install 'Claude Code' 'irm https://claude.ai/install.ps1 | iex') {
      Write-Say "running: irm https://claude.ai/install.ps1 | iex"
      try {
        Invoke-Expression (Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')
        Write-Ok "Claude Code installed."
      } catch {
        Write-Warn "Claude Code install failed - continuing."
        Set-PrereqFailed
      }
      if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and
          (Test-Path -LiteralPath (Join-Path $BinDir 'claude.exe'))) {
        Write-Warn "claude landed in $BinDir but is not on PATH in this session yet."
      }
    } else {
      Write-Warn "skipped Claude Code."
      Set-PrereqFailed
    }
  }
}

# --- PATH --------------------------------------------------------------------

function Add-UserPath {
  param([string]$Dir)

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($null -eq $userPath) { $userPath = '' }

  $parts = @($userPath -split ';' | Where-Object { $_ -ne '' })
  if ($parts -contains $Dir) {
    Write-Say "$Dir is already on the user PATH"
  } else {
    Write-Say "persisting PATH for future sessions: $Dir"
    $joined = (@($parts) + $Dir) -join ';'
    Invoke-Step "append $Dir to the user PATH" {
      [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
    }
  }

  # The script is a subprocess, so it cannot change the PATH of the shell that
  # launched it - the one the user actually types into. Prepending to our own
  # PATH is still worth doing, because the proxy manager below is our child and
  # inherits it: without this the install could finish and then fail to start
  # the very proxy it just installed.
  $sessionParts = @($env:Path -split ';' | Where-Object { $_ -ne '' })
  if ($sessionParts -notcontains $Dir) {
    $env:Path = "$Dir;$env:Path"
    Write-Say "$Dir added to PATH for this run"

    # ...but the user's shell is untouched, and it is the one that matters when
    # they type `zim-claude`. Say so, or they will meet "not recognized" with
    # nothing explaining it.
    Write-Warn "$Dir is not on PATH in THIS window."
    Write-Warn "For this window, run:"
    Write-Warn "    `$env:Path = `"$Dir;`$env:Path`""
    Write-Warn "A new terminal will pick it up on its own."
  }
}

# --- the user's shell profile ------------------------------------------------
#
# The PowerShell profile commonly carries the same ANTHROPIC_* assignments.
# If they aim at the local proxy but carry a key this repo did not issue, plain
# `claude` would use them and fail on every request. Only that case triggers a
# rewrite; a profile aimed elsewhere, or already carrying our key, is reported
# by Test-Conflicts and never changed.
function Update-ShellProfile {
  param([string]$Token, [int]$ProxyPort)
  if ([string]::IsNullOrEmpty($Token)) { return }

  $profiles = @(
    (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
  )

  foreach ($p in $profiles) {
    if (-not (Test-Path -LiteralPath $p)) { continue }

    $lines = @(Get-Content -LiteralPath $p)
    $rcToken = ''
    $rcUrl   = ''
    foreach ($line in $lines) {
      if ($line -match '^\s*\$env:ANTHROPIC_AUTH_TOKEN\s*=\s*["'']?(.*?)["'']?\s*$') { $rcToken = $Matches[1] }
      if ($line -match '^\s*\$env:ANTHROPIC_BASE_URL\s*=\s*["'']?(.*?)["'']?\s*$')  { $rcUrl   = $Matches[1] }
    }
    if ([string]::IsNullOrEmpty($rcToken)) { continue }
    if (-not (Test-LocalProxyUrl -Url $rcUrl)) { continue }
    if ($rcToken -eq $Token) { continue }

    Backup-IfExists -Path $p
    Write-Say "replacing the stale key in $p with the Token Juice key from $EnvFile"
    if ($DryRun) {
      Write-Host "    would rewrite the ANTHROPIC_* assignments (token redacted)"
      continue
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
      if ($line -match '^\s*\$env:ANTHROPIC_BASE_URL\s*=') {
        $out.Add("`$env:ANTHROPIC_BASE_URL = `"http://localhost:$ProxyPort`"")
      } elseif ($line -match '^\s*\$env:ANTHROPIC_AUTH_TOKEN\s*=') {
        $out.Add("`$env:ANTHROPIC_AUTH_TOKEN = `"$Token`"")
      } elseif ($line -match '^\s*\$env:ANTHROPIC_MODEL\s*=') {
        $out.Add('$env:ANTHROPIC_MODEL = "deepseek-v4.1-flash-1017"')
      } elseif ($line -match '^\s*\$env:ANTHROPIC_API_KEY\s*=') {
        $out.Add('$env:ANTHROPIC_API_KEY = ""')
      } else {
        $out.Add($line)
      }
    }
    [IO.File]::WriteAllText($p, ($out -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))
    Write-Ok "updated $p (port $ProxyPort)"
  }
}

# --- advisory conflict checks (warn only - never mutate) ---------------------

function Test-Conflicts {
  $profilePaths = @(
    (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
  )
  foreach ($p in $profilePaths) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    if (-not (Select-String -LiteralPath $p -Pattern 'ANTHROPIC_' -Quiet)) { continue }
    # After a migration the file holds OUR values; warning about them would be
    # noise about a conflict that no longer exists.
    if (-not [string]::IsNullOrEmpty($script:EffectiveToken) -and
        (Select-String -LiteralPath $p -Pattern ([regex]::Escape($script:EffectiveToken)) -Quiet)) {
      continue
    }
    Write-Warn "$p sets ANTHROPIC_* - plain 'claude' uses that provider."
    Write-Warn "'zim-claude' overrides it for its own process only."
  }

  # Claude Code applies a settings.json "env" block AFTER inheriting the process
  # environment, so it would silently win over the wrapper.
  $s = Join-Path $env:USERPROFILE '.claude\settings.json'
  if (Test-Path -LiteralPath $s) {
    try {
      $d = Get-Content -LiteralPath $s -Raw | ConvertFrom-Json
      $names = @($d.PSObject.Properties.Name)
      if ($names -contains 'env') {
        $keys = @($d.env.PSObject.Properties.Name | Where-Object { $_ -like 'ANTHROPIC_*' })
        if ($keys.Count -gt 0) {
          Write-Warn "$s sets ANTHROPIC_* in its `"env`" block; that WINS over zim-claude:"
          foreach ($k in $keys) { Write-Warn "      $k" }
        }
      }
    } catch { }
  }
}

# --- uninstall ---------------------------------------------------------------

function Invoke-Uninstall {
  Write-Say "uninstalling zim-claude"

  foreach ($e in @(Read-State)) {
    if (-not (Test-Path -LiteralPath $e.path)) { Write-Say "already gone: $($e.path)"; continue }
    if (Test-FileIsOurs -Path $e.path) {
      Write-Say "removing $($e.path)"
      Invoke-Step "remove $($e.path)" { Remove-Item -LiteralPath $e.path -Force }
    } else {
      Write-Warn "modified since install - leaving: $($e.path)"
      Write-Warn "  backup from install time is under $BackupRoot"
    }
  }

  # Never touch user data. ~USERPROFILE%\tokenjuice holds the credential and the
  # model-name configuration, and other harnesses on this machine use the same
  # files, so both stay put.
  Write-Say "keeping $EnvFile (your credential - delete it yourself if you want)"
  Write-Say "keeping $CliConfig (the model-name configuration - shared, left alone)"

  # Auto-update bookkeeping goes: a later wrapper from a fresh install must not
  # inherit a stale checkout path.
  if (Test-Path -LiteralPath $UpdateConf) {
    Write-Say "removing $UpdateConf"
    Invoke-Step "remove $UpdateConf" { Remove-Item -LiteralPath $UpdateConf -Force }
  }

  Invoke-Step "remove $StateFile" { Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue }
  Write-Ok "uninstalled."
}

# --- main --------------------------------------------------------------------

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# Refuse to run on non-Windows rather than half-working. $IsWindows only exists
# on PowerShell 6+, so on 5.1 assume Windows (that is where it ships).
$onWindows = $true
if ($PSVersionTable.PSVersion.Major -ge 6) { $onWindows = $IsWindows }
if (-not $onWindows) {
  Write-Err "this installer is for Windows. On Linux/macOS use ./install.sh."
  exit 2
}

if ($Uninstall) {
  Invoke-Uninstall
  exit 0
}

Write-Say "zim-claude installer (Windows)"
Write-Say "source:  $SrcDir"
Write-Say "target:  $BinDir"
if ($DryRun) { Write-Warn "DRY RUN - nothing will be changed" }

Test-Prereqs

if (-not $SkipCli) {
  Write-Say "installing the CLI side (port auto-detected)"
  Install-File -Src (Join-Path $WinDir 'zim-claude.cmd')    -Dest (Join-Path $BinDir 'zim-claude.cmd')    -Scope 'cli' | Out-Null
  Install-File -Src (Join-Path $WinDir 'zim-claude.ps1')    -Dest (Join-Path $BinDir 'zim-claude.ps1')    -Scope 'cli' | Out-Null
  Install-File -Src (Join-Path $WinDir 'zim-claude-update.ps1') -Dest (Join-Path $BinDir 'zim-claude-update.ps1') -Scope 'cli' | Out-Null
  Install-File -Src (Join-Path $WinDir 'zim-claude-update.cmd') -Dest (Join-Path $BinDir 'zim-claude-update.cmd') -Scope 'cli' | Out-Null
  # The model-name config lives in %USERPROFILE%\tokenjuice and is shared, so it
  # is only created when missing; an existing one is never rewritten.
  if (Test-Path -LiteralPath $CliConfig) {
    Write-Say "using the model configuration already in place: $CliConfig"
  } else {
    Install-File -Src (Join-Path $SrcDir 'config\litellm-config.yaml') -Dest $CliConfig -Scope 'cli' | Out-Null
  }
  Write-UpdateConf
}

# Shared by both sides: one manager drives both proxies, and both read the same
# ANTHROPIC_AUTH_TOKEN out of this one profile. So `-SkipCli` alone must still
# leave the :4002 gateway startable and able to authenticate.
if (-not $SkipCli -or -not $SkipDesktop) {
  Install-File -Src (Join-Path $WinDir 'start-proxies.ps1') -Dest (Join-Path $BinDir 'start-proxies.ps1') -Scope 'shared' | Out-Null
  Install-File -Src (Join-Path $WinDir 'start-proxies.cmd') -Dest (Join-Path $BinDir 'start-proxies.cmd') -Scope 'shared' | Out-Null
  Install-EnvProfile | Out-Null
  Update-ShellProfile -Token $script:EffectiveToken -ProxyPort $script:EffectivePort
}

if (-not $SkipDesktop) {
  Write-Say "installing the Claude Desktop side (:4002)"
  Install-DesktopConfig | Out-Null
  Install-File -Src (Join-Path $WinDir 'verify.ps1') -Dest (Join-Path $BinDir 'verify.ps1') -Scope 'desktop' | Out-Null
  Install-File -Src (Join-Path $WinDir 'verify.cmd') -Dest (Join-Path $BinDir 'verify.cmd') -Scope 'desktop' | Out-Null
}

Add-UserPath -Dir $BinDir
Test-Conflicts

Write-Host ''
if ($script:PrereqFailed) {
  Write-Warn "install incomplete - missing prerequisites (see above)."
}
Write-Ok "done. Try:  zim-claude --version"

Write-Host ''
Write-Warn "Token Juice is down: its unlimited quota ended."
Write-Say "  zim-claude no longer routes to it. Run zim-claude and it will offer"
Write-Say "  TokenHarbor (https://tokenharbor.ai) instead; your answer is remembered."
Write-Say "  The proxy route above stays installed for other harnesses and for anyone"
Write-Say "  with a Token Juice key of their own."

if (-not $NoStart) {
  Write-Host ''
  Write-Say "starting the LiteLLM proxies"
  $mgr = Join-Path $BinDir 'start-proxies.ps1'
  if (-not (Test-Path -LiteralPath $mgr)) { $mgr = Join-Path $WinDir 'start-proxies.ps1' }
  try { & powershell -NoProfile -ExecutionPolicy Bypass -File $mgr start }
  catch { Write-Warn "proxies did not start - see the logs under $StateDir\logs" }
}

if (-not $SkipDesktop) {
  Write-Host ''
  Write-Say "Point Claude Desktop at the gateway"
  Write-Host ""
  Write-Host "  In Claude Desktop:"
  Write-Host "    1. Help -> Troubleshooting -> Enable Developer Mode"
  Write-Host "    2. Claude menu -> Developer -> Configure Third-Party Inference..."
  Write-Host "    3. Connection section:"
  Write-Host "         Inference provider  : Gateway"
  Write-Host "         Gateway base URL    : http://127.0.0.1:$DeskProxyPort"
  Write-Host "         Gateway API key     : $GatewayKey"
  Write-Host "         Gateway auth scheme : bearer"
  Write-Host "    4. Apply Changes (older builds: `"Apply locally`"), then restart Claude Desktop."
  Write-Host ""
  Write-Host "  Model that will appear in the picker:  claude-opus-5-5"
  Write-Host ""
  Write-Host "  Verify from the shell:  verify.ps1"
  Write-Host ""
  Write-Host "  Heads-up: enabling third-party inference replaces the subscription"
  Write-Host "  account path for the desktop app. Flip the provider back to default"
  Write-Host "  to return to your Claude account."
}

if ($script:PrereqFailed) { exit 1 }
exit 0
