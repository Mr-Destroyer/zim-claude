@echo off
rem start-proxies.cmd - Windows entry point for start-proxies.ps1.
rem
rem A .ps1 cannot be run by bare name: cmd, PowerShell's bare-command lookup, and
rem any program calling us as a subprocess all need a real executable. A .cmd is
rem one; a .ps1 is not.
rem
rem It is also what lets the documented forms work on a machine whose execution
rem policy refuses a bare .ps1 - which is the default on Windows clients, and
rem also what happens to any file that arrived in a downloaded ZIP.
rem
rem All arguments are forwarded verbatim, so `start-proxies status -Which desktop`
rem and the rest of the README's forms work unchanged.
rem -ExecutionPolicy Bypass is scoped to this invocation only; it does not change
rem the machine's policy. -NoProfile keeps a user profile from altering the run.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-proxies.ps1" %*

rem Propagate the exit code. Without this, cmd would report the exit code of the
rem last command in this file and swallow failures.
exit /b %ERRORLEVEL%
