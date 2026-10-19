<#
.SYNOPSIS
  Install zim-claude and the Claude Desktop gateway on Windows.

.DESCRIPTION
  One installer for both sides, because on Windows they are always wanted
  together:

    CLI      :4000   Claude Code CLI         (the zim-claude command)
    Desktop  :4002   Claude Desktop gateway  (Third-Party Inference)

  It mirrors the behaviour of the two bash installers (install.sh at the repo
  root, and claude-desktop-integration/install.sh) rather than their code:
  dry-run, backups, content-comparison, a state file so uninstall only removes
  what it installed and left unmodified, and a credential that is never
  overwritten.

  Run windows\win-install.bat, which shims to this file.

.PARAMETER SkipCli
  Do not install the CLI side (:4000).

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
$HomeSrc   = Join-Path $env:USERPROFILE 'claude-source'
$EnvFile   = Join-Path $HomeSrc 'deepseek-claude'
$CliConfig = Join-Path $env:USERPROFILE 'litellm-config.yaml'

$StateDir   = Join-Path $env:USERPROFILE '.local\share\zim-claude'
$StateFile  = Join-Path $StateDir 'installed.json'
$BackupRoot = Join-Path $StateDir 'backups'
$Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir  = Join-Path $BackupRoot $Stamp

$DeskConfigDir = Join-Path $StateDir 'desktop'
$DeskConfig    = Join-Path $DeskConfigDir 'litellm-config.desktop.yaml'

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
function Install-EnvProfile {
  Invoke-Step "mkdir $HomeSrc" { New-Item -ItemType Directory -Force -Path $HomeSrc | Out-Null }

  # Plaintext token file. Trims surrounding whitespace, including the CR that a
  # Windows checkout or a browser copy-paste adds - a trailing CR inside the
  # export produces a 401 that looks like a bad key.
  $token = ''
  $src = ''
  $tokenPath = Join-Path $SrcDir 'config\token'
  $b64Path   = Join-Path $SrcDir 'config\.token.b64'

  if (Test-Path -LiteralPath $tokenPath) {
    $src = $tokenPath
    $token = (Get-Content -LiteralPath $tokenPath -Raw) -replace '\s', ''
  } elseif (Test-Path -LiteralPath $b64Path) {
    # Legacy layout: base64 blob. Kept so an existing checkout still installs.
    $src = $b64Path
    try {
      $b64 = (Get-Content -LiteralPath $b64Path -Raw) -replace '\s', ''
      $token = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))) -replace '\s', ''
    } catch { $token = '' }
  }

  if (Test-Path -LiteralPath $EnvFile) {
    # A legacy Token Juice profile (tj_ key) is useless against Logfare: the
    # proxy forwards the key upstream and every request 401s, so the install
    # would look fine and fail on first use. That one case is migrated, with a
    # backup. Any other credential is the user's own and is left alone.
    $current = ''
    foreach ($line in Get-Content -LiteralPath $EnvFile -ErrorAction SilentlyContinue) {
      if ($line -match '^export\s+ANTHROPIC_AUTH_TOKEN="(.*)"$') {
        $current = $Matches[1]
        break
      }
    }

    if ($current -notlike 'tj_*') {
      Write-Say "keeping existing env file: $EnvFile (never overwritten)"
      return $true
    }

    if ([string]::IsNullOrEmpty($token)) {
      Write-Err "existing env file has a Token Juice token, but $SrcDir\config\token is missing"
      Write-Err "  cannot migrate it to Logfare - re-clone or restore config\token"
      return $false
    }
    Backup-IfExists -Path $EnvFile
    Write-Say "migrating env file from Token Juice to Logfare: $EnvFile"
    if ($DryRun) {
      Write-Host "    would rewrite 4 ANTHROPIC_* exports (token redacted)"
      return $true
    }
    # Fall through to the writer below, which overwrites the file wholesale.
  }

  if ([string]::IsNullOrEmpty($token)) {
    Write-Err "no token found in $SrcDir\config\"
    Write-Err "  expected config\token to hold the ANTHROPIC_AUTH_TOKEN"
    return $false
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
    'export ANTHROPIC_BASE_URL="http://localhost:4000"'
    "export ANTHROPIC_AUTH_TOKEN=`"$token`""
    'export ANTHROPIC_MODEL="deepseek-v4.1-flash"'
    'export ANTHROPIC_API_KEY=""'
  ) -join "`n"
  # Explicit LF, no BOM: a CRLF here would put a CR inside the token.
  [IO.File]::WriteAllText($EnvFile, $content + "`n", (New-Object Text.UTF8Encoding $false))
  Write-Ok "wrote $EnvFile"
  return $true
}

function Install-DesktopConfig {
  $src = Join-Path $SrcDir 'claude-desktop-integration\litellm-config.desktop.yaml'
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Err "missing source file: $src"
    return $false
  }

  if (Test-Path -LiteralPath $DeskConfig) {
    if ((Get-FileHashString -Path $src) -eq (Get-FileHashString -Path $DeskConfig)) {
      Write-Say "unchanged: $DeskConfig"
      return $true
    }
    if (-not $Force -and -not (Test-FileIsOurs -Path $DeskConfig)) {
      Write-Warn "you have modified this file - leaving it alone: $DeskConfig"
      Write-Warn "  re-run with -Force to overwrite (a backup is still taken)"
      return $false
    }
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

# --- advisory conflict checks (warn only - never mutate) ---------------------

function Test-Conflicts {
  $profilePaths = @(
    (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
  )
  foreach ($p in $profilePaths) {
    if ((Test-Path -LiteralPath $p) -and (Select-String -LiteralPath $p -Pattern 'ANTHROPIC_' -Quiet)) {
      Write-Warn "$p sets ANTHROPIC_* - plain 'claude' uses that provider."
      Write-Warn "'zim-claude' overrides it for its own process only."
    }
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

  # Never touch user data. The env file is a credential and claude-source\ may
  # also hold unrelated profiles, so both stay put.
  Write-Say "keeping $EnvFile (your credential - delete it yourself if you want)"

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
  Write-Say "installing the CLI side (:4000)"
  Install-File -Src (Join-Path $WinDir 'zim-claude.cmd')    -Dest (Join-Path $BinDir 'zim-claude.cmd')    -Scope 'cli' | Out-Null
  Install-File -Src (Join-Path $WinDir 'zim-claude.ps1')    -Dest (Join-Path $BinDir 'zim-claude.ps1')    -Scope 'cli' | Out-Null
  Install-File -Src (Join-Path $SrcDir 'config\litellm-config.yaml') -Dest $CliConfig -Scope 'cli' | Out-Null
}

# Shared by both sides: one manager drives both proxies, and both read the same
# ANTHROPIC_AUTH_TOKEN out of this one profile. So `-SkipCli` alone must still
# leave the :4002 gateway startable and able to authenticate.
if (-not $SkipCli -or -not $SkipDesktop) {
  Install-File -Src (Join-Path $WinDir 'start-proxies.ps1') -Dest (Join-Path $BinDir 'start-proxies.ps1') -Scope 'shared' | Out-Null
  Install-File -Src (Join-Path $WinDir 'start-proxies.cmd') -Dest (Join-Path $BinDir 'start-proxies.cmd') -Scope 'shared' | Out-Null
  Install-EnvProfile | Out-Null
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
