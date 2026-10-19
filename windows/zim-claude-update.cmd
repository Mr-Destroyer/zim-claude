@echo off
rem zim-claude-update.cmd - Windows entry point for zim-claude-update.ps1.
rem
rem The wrapper starts the .ps1 directly with powershell -File, so this shim is
rem not on the automatic path. It exists so the updater can also be run by hand
rem (`zim-claude-update`) on a machine whose execution policy refuses a bare
rem .ps1 - the default on Windows clients.
rem
rem -ExecutionPolicy Bypass is scoped to this invocation only; it does not change
rem the machine's policy. -NoProfile keeps a user profile from altering the run.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zim-claude-update.ps1" %*

rem Propagate the exit code, so a failed update is visible to callers.
exit /b %ERRORLEVEL%
