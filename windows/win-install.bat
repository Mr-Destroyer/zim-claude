@echo off
setlocal
rem win-install.bat - install zim-claude and the Claude Desktop gateway on Windows.
rem
rem This is the entry point. It is a .bat rather than a .ps1 for two reasons:
rem double-clicking it works, and it runs even when the machine's execution
rem policy would refuse a bare .ps1.
rem
rem All flags pass straight through to win-install.ps1:
rem
rem   win-install.bat -DryRun       print every action, change nothing
rem   win-install.bat               install both sides and start the proxies
rem   win-install.bat -SkipDesktop  CLI proxy only
rem   win-install.bat -SkipCli      Claude Desktop gateway (:4002) only
rem   win-install.bat -NoStart      install but do not start the proxies
rem   win-install.bat -Force        overwrite hand-edited files (backed up first)
rem   win-install.bat -Port N       use port N instead of auto-detecting one
rem   win-install.bat -Uninstall    remove what the installer created
rem   win-install.bat -Help
rem
rem -ExecutionPolicy Bypass applies to this invocation only; it does not change
rem the machine's policy. -NoProfile keeps a user profile from altering the run.

set "SCRIPT=%~dp0win-install.ps1"

if not exist "%SCRIPT%" (
  echo [x] cannot find "%SCRIPT%"
  echo     run this from inside the repo's windows\ directory.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
