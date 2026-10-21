@echo off
rem zim-claude.cmd - Windows entry point for the zim-claude wrapper.
rem
rem This shim exists because a .ps1 cannot be run by bare name: cmd, PowerShell's
rem bare-command lookup, and any program calling us as a subprocess all need a
rem real executable. A .cmd is one; a .ps1 is not.
rem
rem It is also what makes `zim-claude ...` work identically in cmd.exe and in
rem PowerShell - PowerShell finds zim-claude.cmd on PATH and runs it.
rem
rem All arguments are forwarded verbatim. `%*` preserves quoting as cmd received
rem it, so flags, subcommands and quoted strings with spaces all survive.
rem -ExecutionPolicy Bypass is scoped to this invocation only; it does not change
rem the machine's policy. -NoProfile keeps a user profile from altering the run.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zim-claude.ps1" %*

rem Propagate claude's exit code. Without this, cmd would report the exit code of
rem the last command in this file and swallow failures.
exit /b %ERRORLEVEL%
