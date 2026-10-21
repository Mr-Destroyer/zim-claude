@echo off
rem verify.cmd - Windows entry point for verify.ps1.
rem
rem Same reason as start-proxies.cmd: verify.ps1 cannot be run by bare name, and
rem a machine whose execution policy refuses a bare .ps1 - the default on Windows
rem clients, and what happens to anything from a downloaded ZIP - would otherwise
rem block the one command that proves the Desktop gateway works.
rem
rem All arguments are forwarded verbatim, so `verify -Model some-model` works.
rem -ExecutionPolicy Bypass is scoped to this invocation only; it does not change
rem the machine's policy. -NoProfile keeps a user profile from altering the run.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify.ps1" %*

rem Propagate the exit code, so a failed check is visible to callers and scripts.
exit /b %ERRORLEVEL%
