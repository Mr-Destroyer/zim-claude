<#
.SYNOPSIS
  Bring an installed zim-claude up to date, quietly.

.DESCRIPTION
  Windows counterpart of scripts/zim-claude-update.sh. The zim-claude wrapper
  starts this in the background before handing off to claude; it is also safe
  to run by hand.

  What it does:
    1. rate-limits itself (default: at most once an hour)
    2. takes a lock, so two sessions cannot update at the same time
    3. refuses a checkout with local changes
    4. fetches the recorded branch and fast-forwards ONLY
    5. re-runs the checkout's win-install.ps1, which installs atomically

  What it deliberately does NOT do:
    - block or delay claude: the wrapper starts it detached
    - report failure to the caller: every outcome is a log line and exit 0
    - force, reset, stash or merge: a diverged checkout is left alone
    - restart the proxy: a running session keeps its proxy and config

  Configuration is written by win-install.ps1 to
  %USERPROFILE%\.local\share\zim-claude\update.json.

.NOTES
  No secrets live in this file. The repository URL and branch come from the
  checkout itself.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$StateDir = Join-Path $env:USERPROFILE '.local\share\zim-claude'
$ConfPath = Join-Path $StateDir 'update.json'
$LogPath  = Join-Path $StateDir 'update.log'
$StampPath = Join-Path $StateDir 'last-update-check'
$LockPath = Join-Path $StateDir 'update.lock'

$Interval = 3600
if ($env:ZIM_CLAUDE_UPDATE_INTERVAL) { $Interval = [int]$env:ZIM_CLAUDE_UPDATE_INTERVAL }

function Write-Log {
  param([string]$Message)
  try {
    $line = "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz') $Message"
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch { }
}

function Set-Stamp {
  try { Set-Content -LiteralPath $StampPath -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Encoding ASCII } catch { }
}

function Exit-Quiet { exit 0 }

try {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
} catch { Exit-Quiet }

# Keep the log bounded; it is appended to and never read by the wrapper.
try {
  if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 262144)) {
    Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force -ErrorAction SilentlyContinue
  }
} catch { }

# Serialize with a lock file. Windows PowerShell has no flock; opening the
# file with FileShare.None gives the same one-at-a-time guarantee, and the
# handle is released when this process exits.
$lockStream = $null
try {
  $lockStream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate,
                                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch {
  Exit-Quiet
}

# Rate limit. A fresh install has no stamp, so the first run checks once.
if ($env:ZIM_CLAUDE_UPDATE_FORCE -ne '1' -and (Test-Path -LiteralPath $StampPath)) {
  $last = 0
  try { [void][long]::TryParse((Get-Content -LiteralPath $StampPath -Raw -ErrorAction Stop).Trim(), [ref]$last) } catch { $last = 0 }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if (($now - $last) -lt $Interval) { Exit-Quiet }
}

if (-not (Test-Path -LiteralPath $ConfPath)) {
  Write-Log "update.json missing - auto-update is not configured"
  Exit-Quiet
}

$conf = $null
try { $conf = Get-Content -LiteralPath $ConfPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
  Write-Log "update.json unreadable - skipping"
  Exit-Quiet
}

# Read defensively: StrictMode 2.0 makes a missing property fatal.
$auto = $false
if ($conf.PSObject.Properties['autoUpdate']) { $auto = [bool]$conf.autoUpdate }
if (-not $auto) { Exit-Quiet }

$repo = ''
$branch = ''
if ($conf.PSObject.Properties['repoDir']) { $repo = [string]$conf.repoDir }
if ($conf.PSObject.Properties['branch'])  { $branch = [string]$conf.branch }

if ([string]::IsNullOrEmpty($repo) -or [string]::IsNullOrEmpty($branch)) {
  Write-Log "auto-update is not configured for this install"
  Exit-Quiet
}
if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
  Write-Log "checkout is gone: $repo - skipping"
  Exit-Quiet
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Log "git not found - skipping"
  Exit-Quiet
}

# Only tracked modifications block an update; untracked files are allowed and
# a fast-forward that would overwrite one simply fails below.
$dirty = & git -C $repo status --porcelain --untracked-files=no 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Log "git status failed in $repo - skipping"
  Exit-Quiet
}
if ($dirty) {
  Write-Log "checkout has local changes - not updating ($repo)"
  Exit-Quiet
}

& git -C $repo fetch --quiet origin $branch *>> $LogPath
if ($LASTEXITCODE -ne 0) {
  Write-Log "fetch failed for origin/$branch - will retry after the interval"
  Set-Stamp
  Exit-Quiet
}

$localRev  = (& git -C $repo rev-parse HEAD 2>$null)
$remoteRev = (& git -C $repo rev-parse "refs/remotes/origin/$branch" 2>$null)
if ([string]::IsNullOrEmpty($localRev) -or [string]::IsNullOrEmpty($remoteRev)) {
  Write-Log "could not resolve $branch revisions - skipping"
  Set-Stamp
  Exit-Quiet
}
if ($localRev -eq $remoteRev) {
  Write-Log ("already up to date ({0})" -f $localRev.Substring(0, [Math]::Min(12, $localRev.Length)))
  Set-Stamp
  Exit-Quiet
}

# Fast-forward only. A local commit, a rewritten history or a force-push all
# land here and are left for the user to resolve.
& git -C $repo merge-base --is-ancestor $localRev $remoteRev 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Log "local $branch has diverged from origin/$branch - not updating"
  Set-Stamp
  Exit-Quiet
}

& git -C $repo merge --ff-only --quiet $remoteRev *>> $LogPath
if ($LASTEXITCODE -ne 0) {
  Write-Log "fast-forward failed - not updating"
  Set-Stamp
  Exit-Quiet
}

Write-Log ("updated {0} -> {1}" -f $localRev.Substring(0, [Math]::Min(12, $localRev.Length)),
                                  $remoteRev.Substring(0, [Math]::Min(12, $remoteRev.Length)))

# Install what was pulled. -NoStart so a background update never restarts a
# proxy out from under a running session. stdin is not attached, so the
# prerequisite prompts decline and the CLI half still installs.
$installer = Join-Path $repo 'windows\win-install.bat'
if (Test-Path -LiteralPath $installer) {
  & $installer -NoStart *>> $LogPath
  Write-Log "installer exited $LASTEXITCODE"
} else {
  Write-Log "no win-install.bat in $repo - files updated but not installed"
}

Set-Stamp
Exit-Quiet
