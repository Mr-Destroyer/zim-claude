#!/usr/bin/env bash
# run-tests.sh — end-to-end tests for the zim-claude package.
#
# Everything runs against a throwaway sandbox $HOME, so the real ~ is never
# touched. Usage:  ./tests/run-tests.sh

set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
STUB="$REPO/tests/stub/claude"

PASS=0 FAIL=0 SKIP=0

c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'

pass() { PASS=$((PASS + 1)); printf '  %sPASS%s %s\n' "$c_g" "$c_0" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  %sFAIL%s %s\n' "$c_r" "$c_0" "$1"
         [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); printf '  %sSKIP%s %s\n' "$c_y" "$c_0" "$1"; }
section() { printf '\n%s== %s%s\n' "$c_b" "$1" "$c_0"; }

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"
  else fail "$1" "expected: $(printf '%q' "$2")  actual: $(printf '%q' "$3")"; fi
}

# assert_contains <label> <needle> <haystack>
assert_contains() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"
  else fail "$1" "expected to contain: $(printf '%q' "$2")"$'\n'"got: $3"; fi
}

# ---------------------------------------------------------------- static ----

section "static checks"

for f in "$REPO/install.sh" "$REPO/scripts/zim-claude" "$REPO/scripts/start-litellm.sh" "$STUB"; do
  if bash -n "$f" 2>/dev/null; then pass "syntax: ${f#"$REPO"/}"
  else fail "syntax: ${f#"$REPO"/}" "$(bash -n "$f" 2>&1)"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in "$REPO/install.sh" "$REPO/scripts/zim-claude"; do
    if shellcheck -S warning "$f" >/dev/null 2>&1; then pass "shellcheck: ${f#"$REPO"/}"
    else fail "shellcheck: ${f#"$REPO"/}" "$(shellcheck -S warning "$f" 2>&1 | head -5)"; fi
  done
else
  skip "shellcheck not installed"
fi

# The shipped copies must be byte-identical to the working originals, or the
# package silently drifts from the setup that is known to work.
if [[ -f "$HOME/start-litellm.sh" ]]; then
  if diff -q "$HOME/start-litellm.sh" "$REPO/scripts/start-litellm.sh" >/dev/null; then
    pass "start-litellm.sh matches ~/start-litellm.sh"
  else fail "start-litellm.sh drifted from ~/start-litellm.sh"; fi
else skip "~/start-litellm.sh absent — cannot diff"; fi

if [[ -f "$HOME/litellm-config.yaml" ]]; then
  if diff -q "$HOME/litellm-config.yaml" "$REPO/config/litellm-config.yaml" >/dev/null; then
    pass "litellm-config.yaml matches ~/litellm-config.yaml"
  else fail "litellm-config.yaml drifted"; fi
else skip "~/litellm-config.yaml absent — cannot diff"; fi

# No hardcoded home directory anywhere — the package must work for any user.
if hits="$(grep -rn '/home/zim' "$REPO" --exclude-dir=.git --exclude-dir=tests 2>/dev/null)"; then
  fail "no hardcoded /home/zim" "$hits"
else pass "no hardcoded /home/zim"; fi

# --- the proxy virtualenv ---
# install.sh builds the venv and start-litellm.sh looks for it. They are two
# separate files that a future edit could easily move apart, and the failure is
# silent: the installer would build a venv the proxy never looks in, and the
# proxy would report "litellm not found" on a machine that just installed it.
#
# install.sh composes the path from $STATE_DIR, so the literal string only ever
# appears in start-litellm.sh. Assert both halves: STATE_DIR is where the proxy
# looks, and the venv hangs off it.
if grep -qF 'STATE_DIR="$HOME/.local/share/zim-claude"' "$REPO/install.sh" &&
   grep -qF 'PROXY_VENV="$STATE_DIR/venv"' "$REPO/install.sh" &&
   grep -qF '$HOME/.local/share/zim-claude/venv' "$REPO/scripts/start-litellm.sh"; then
  pass "venv path agreed by install.sh and start-litellm.sh"
else
  fail "venv path disagrees between install.sh and start-litellm.sh" \
       "install.sh would build a venv the proxy never looks for"
fi

# Both floors are load-bearing, and lowering either fails in a way that still
# looks healthy — so assert them by name rather than trusting a future edit.
#   litellm>=1.100.1: older litellm 500s on /v1/messages for openai/* models
#     (the only route Claude Code uses) while /v1/chat/completions keeps working.
#   uvloop>=0.22.1: below that it imports BaseDefaultEventLoopPolicy, removed in
#     Python 3.14, so the proxy dies at startup and never binds its port.
if grep -qF 'litellm[proxy]>=1.100.1' "$REPO/install.sh"; then
  pass "install.sh pins litellm[proxy]>=1.100.1"
else fail "install.sh lost the litellm>=1.100.1 floor" "openai/* models would 500 on /v1/messages"; fi
if grep -qF 'uvloop>=0.22.1' "$REPO/install.sh"; then
  pass "install.sh pins uvloop>=0.22.1"
else fail "install.sh lost the uvloop>=0.22.1 floor" "the proxy would die at startup on Python 3.14"; fi

# The venv removes the reason --break-system-packages was ever needed. Leaving
# that advice behind would send users back to mutating the system Python.
if hits="$(grep -rn 'break-system-packages' "$REPO/install.sh" "$REPO/scripts" 2>/dev/null)"; then
  fail "no --break-system-packages advice remains" "$hits"
else pass "no --break-system-packages advice remains"; fi

# The token ships in plaintext (config/token) by design — it has to survive a
# fresh clone, and a base64 blob that GitHub's web uploader silently skips does
# not. What matters is that the file is present, non-empty, and tracked.
if [[ -f "$REPO/config/token" ]]; then
  if [[ -n "$(tr -d ' \t\r\n' < "$REPO/config/token")" ]]; then
    pass "config/token holds a non-empty token"
  else fail "config/token is empty"; fi
else fail "config/token missing"; fi

# A clone that lacks the token installs a broken wrapper. This is the exact
# failure that shipped: the file existed locally but was never committed.
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$REPO" ls-files --error-unmatch config/token >/dev/null 2>&1; then
    pass "config/token is tracked by git"
  else fail "config/token is NOT tracked — a fresh clone will not have it"; fi
else skip "not a git checkout — cannot verify tracking"; fi

# ------------------------------------------------------------- windows ------

section "windows artifacts"

# The Windows port is PowerShell, which this Linux box cannot execute (no pwsh).
# What IS checkable here is that the files exist and that the shims point at the
# right targets: a .bat wired to a renamed .ps1 is a silent, total failure that
# no amount of review would catch, and it is exactly what a rename would break.
for f in win-install.bat win-install.ps1 zim-claude.cmd zim-claude.ps1 \
         start-proxies.ps1 verify.ps1; do
  if [[ -f "$REPO/windows/$f" ]]; then pass "windows/$f present"
  else fail "windows/$f present"; fi
done

# win-install.bat must invoke win-install.ps1.
if grep -q 'win-install\.ps1' "$REPO/windows/win-install.bat" 2>/dev/null; then
  pass "win-install.bat invokes win-install.ps1"
else fail "win-install.bat does not reference win-install.ps1"; fi

# zim-claude.cmd must invoke zim-claude.ps1.
if grep -q 'zim-claude\.ps1' "$REPO/windows/zim-claude.cmd" 2>/dev/null; then
  pass "zim-claude.cmd invokes zim-claude.ps1"
else fail "zim-claude.cmd does not reference zim-claude.ps1"; fi

# The wrapper must call the proxy manager by the name the installer ships it as.
if grep -q "start-proxies\.ps1" "$REPO/windows/zim-claude.ps1" 2>/dev/null; then
  pass "zim-claude.ps1 references start-proxies.ps1"
else fail "zim-claude.ps1 does not reference start-proxies.ps1"; fi

# Both .cmd shims must propagate the exit code, or failures are swallowed.
for f in win-install.bat zim-claude.cmd start-proxies.cmd verify.cmd; do
  if grep -q 'exit /b %ERRORLEVEL%' "$REPO/windows/$f" 2>/dev/null; then
    pass "$f propagates ERRORLEVEL"
  else fail "$f does not propagate ERRORLEVEL"; fi
done

# Every .ps1 that a user is told to run needs a .cmd/.bat shim beside it.
# A bare .ps1 cannot be run by name, and on a Windows client the default
# execution policy is Restricted - so a documented `start-proxies.ps1 status`
# is blocked outright. The shims pass -ExecutionPolicy Bypass, which is scoped
# to that one invocation and is the only reason the documented forms work.
# This drifted once already: start-proxies.ps1 and verify.ps1 shipped without
# shims while the README documented them as directly runnable.
for ps1 in "$REPO"/windows/*.ps1; do
  [[ -f "$ps1" ]] || continue
  base="$(basename "$ps1" .ps1)"
  if [[ -f "$REPO/windows/$base.cmd" || -f "$REPO/windows/$base.bat" ]]; then
    pass "windows/$base.ps1 has a shim"
  else
    fail "windows/$base.ps1 has no .cmd/.bat shim" \
         "a bare .ps1 is blocked by the default Windows execution policy"
  fi
done

# Each shim must pass -ExecutionPolicy Bypass, or it does not solve that.
for f in win-install.bat zim-claude.cmd start-proxies.cmd verify.cmd; do
  if grep -q -- '-ExecutionPolicy Bypass' "$REPO/windows/$f" 2>/dev/null; then
    pass "$f passes -ExecutionPolicy Bypass"
  else fail "$f does not pass -ExecutionPolicy Bypass"; fi
done

# The Windows scripts must not hardcode a user's home directory.
if hits="$(grep -rniE 'C:\\Users\\[A-Za-z0-9._-]+' "$REPO/windows" 2>/dev/null)"; then
  fail "no hardcoded C:\\Users\\<name> in windows/" "$hits"
else pass "no hardcoded C:\\Users\\<name> in windows/"; fi

# The credential profile and the shared proxy manager must be installed for
# EITHER side. Both proxies read the same ANTHROPIC_AUTH_TOKEN from that one
# profile, so `win-install.bat -SkipCli` — the invocation the desktop README
# recommends — would otherwise leave the :4002 gateway unable to authenticate.
# Anchored on the guard line: Install-EnvProfile also appears inside its own
# definition, so a bare grep would match unconditionally.
if grep -qE '^if \(-not \$SkipCli -or -not \$SkipDesktop\)' "$REPO/windows/win-install.ps1" 2>/dev/null; then
  pass "env profile installed for either side (not skipped with -SkipCli)"
else
  fail "win-install.ps1 gates the env profile on -SkipCli" \
       "-SkipCli would leave the :4002 gateway with no ANTHROPIC_AUTH_TOKEN"
fi

# A dry run must not install prerequisites: Test-Prereqs shells out to winget,
# pip and the Claude Code installer, so answering 'y' would mutate the machine
# during -DryRun and contradict its "change nothing" contract.
if grep -qE '^\s*if \(\$DryRun\) \{' "$REPO/windows/win-install.ps1" 2>/dev/null &&
   awk '/^function Confirm-Install/,/^}/' "$REPO/windows/win-install.ps1" |
     grep -q '\$DryRun'; then
  pass "Confirm-Install is a no-op under -DryRun"
else
  fail "Confirm-Install ignores -DryRun" "-DryRun would still run winget/pip installs"
fi

# Add-UserPath must do BOTH of these, and they are not substitutes:
#   - prepend to its own PATH, so the proxy manager it spawns can find litellm;
#   - still warn that the user's shell is unchanged, since that is the one they
#     type `zim-claude` into. Doing only the first hides why the command is
#     "not recognized" in the window they are looking at.
path_fn="$(awk '/^function Add-UserPath/,/^}/' "$REPO/windows/win-install.ps1")"
if grep -qF '$env:Path = "$Dir;$env:Path"' <<<"$path_fn"; then
  pass "Add-UserPath prepends to PATH for the current run"
else
  fail "Add-UserPath does not prepend to PATH" \
       "the proxy manager it spawns would not find litellm"
fi
if grep -qF 'is not on PATH in THIS window' <<<"$path_fn"; then
  pass "Add-UserPath still warns the user's shell is unchanged"
else
  fail "Add-UserPath stopped warning about the user's shell" \
       "zim-claude would be 'not recognized' with nothing explaining it"
fi

# The gateway key printed for the Desktop dialog must honour
# CLAUDE_DESKTOP_LITELLM_KEY, exactly as start-proxies.ps1 and verify.ps1 do.
# A hardcoded default would print a key the proxy does not enforce, and the app
# would get back {"error":{"message":"No connected db.",...}} — a key mismatch
# that reads as a database problem.
if grep -qF '$env:CLAUDE_DESKTOP_LITELLM_KEY' "$REPO/windows/win-install.ps1" 2>/dev/null; then
  pass "win-install.ps1 honours CLAUDE_DESKTOP_LITELLM_KEY"
else
  fail "win-install.ps1 hardcodes the gateway key" \
       "it would print a key the :4002 proxy rejects as 'No connected db.'"
fi

# --- script encoding ---
# powershell.exe (Windows PowerShell 5.1, which both shims invoke) decodes a
# BOM-less .ps1 with the machine's ANSI codepage, NOT UTF-8. An em dash is the
# byte sequence E2 80 94; CP1252 maps 0x94 to a curly closing quote, and
# PowerShell accepts that as a string terminator. One em dash inside a "..."
# string therefore ends the string early, desynchronises every quote after it,
# and the file dies with "Missing closing '}'" hundreds of lines away — the
# reported line number has nothing to do with the real cause. cmd.exe reads its
# own file through the OEM codepage and fails the same way. Keeping everything
# the Windows port ships pure ASCII removes the codepage from the equation.
for f in "$REPO"/windows/*; do
  [[ -f "$f" ]] || continue
  if LC_ALL=C grep -q '[^[:print:][:space:]]' "$f" 2>/dev/null; then
    fail "windows/$(basename "$f") is pure ASCII" \
         "non-ASCII bytes misparse under PowerShell 5.1 / cmd.exe on a non-UTF-8 codepage"
  else
    pass "windows/$(basename "$f") is pure ASCII"
  fi
done

# Read-State must not hand out entries that lack a `path`. win-install.ps1 runs
# under Set-StrictMode -Version 2.0, where reading a missing property is a fatal
# PropertyNotFoundStrict error rather than $null - so one bad entry (older
# revision, hand-edited file, stray null) aborts the install the moment a caller
# touches .path. That is the "property 'path' cannot be found" crash at the
# Test-FileIsOurs pipeline. The filter is what makes the property access safe.
state_fn="$(awk '/^function Read-State/,/^}/' "$REPO/windows/win-install.ps1")"
if grep -qF "PSObject.Properties['path']" <<<"$state_fn"; then
  pass "Read-State filters entries without a path"
else
  fail "Read-State returns raw entries" \
       "StrictMode 2.0 turns a missing .path into a fatal error mid-install"
fi

# The reader must use the same encoding the writer does. Set-Content -Encoding
# UTF8 emits a BOM on PowerShell 5.1; reading that back under the ANSI default
# prepends junk to the JSON and ConvertFrom-Json rejects it.
if grep -qE 'Get-Content .*-Raw -Encoding UTF8' <<<"$state_fn"; then
  pass "Read-State reads the state file as UTF8"
else
  fail "Read-State reads the state file with the default encoding" \
       "the BOM written by Set-Content -Encoding UTF8 would corrupt the JSON"
fi

# --- line-ending policy ---
# config/token must never be converted: a CR inside the token is a 401 that
# looks like a bad key. The .bat shims need CRLF; the bash side needs LF.
if [[ -f "$REPO/.gitattributes" ]]; then
  pass ".gitattributes present"
  if grep -qE '^[[:space:]]*config/token[[:space:]]+-text' "$REPO/.gitattributes"; then
    pass ".gitattributes pins config/token to -text"
  else fail ".gitattributes does not protect config/token"; fi
  if grep -qE '^[[:space:]]*\*\.bat[[:space:]]+text[[:space:]]+eol=crlf' "$REPO/.gitattributes"; then
    pass ".gitattributes gives *.bat CRLF"
  else fail ".gitattributes does not set *.bat eol=crlf"; fi
else
  fail ".gitattributes present" "a Windows checkout with autocrlf=true would corrupt the bash scripts"
fi

# ---------------------------------------------------------------- sandbox ---

SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-XXXXXX")"
trap 'rm -rf "$SBX"' EXIT

# Run the installer with a HOME that has no ~/.local/bin on PATH, which also
# exercises the PATH-not-set branch.
sbx_install() { env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb bash "$REPO/install.sh" "$@" </dev/null; }

section "install into sandbox \$HOME"

sbx_install >/dev/null 2>&1
# Exit 1 is expected here: the sandbox PATH deliberately omits claude and
# litellm, so the installer reports missing prerequisites. Files still land.
assert_eq "installer reports missing prereqs as exit 1" "1" "$?"
[[ -x "$SBX/.local/bin/zim-claude" ]] && pass "wrapper installed" || fail "wrapper installed"
[[ -x "$SBX/.local/bin/start-litellm.sh" ]] && pass "start-litellm.sh installed" || fail "start-litellm.sh installed"
[[ -f "$SBX/litellm-config.yaml" ]] && pass "litellm-config.yaml installed" || fail "litellm-config.yaml installed"
[[ -f "$SBX/claude-source/deepseek-claude" ]] && pass "env file created" || fail "env file created"

assert_eq "env file mode 600" "600" "$(stat -c%a "$SBX/claude-source/deepseek-claude" 2>/dev/null)"
assert_eq "claude-source dir mode 700" "700" "$(stat -c%a "$SBX/claude-source" 2>/dev/null)"
assert_eq "wrapper mode 755" "755" "$(stat -c%a "$SBX/.local/bin/zim-claude" 2>/dev/null)"
assert_eq "state dir mode 700" "700" "$(stat -c%a "$SBX/.local/share/zim-claude" 2>/dev/null)"

assert_contains "env file has base url" 'ANTHROPIC_BASE_URL="http://localhost:4000"' \
  "$(cat "$SBX/claude-source/deepseek-claude")"
assert_contains "env file clears ANTHROPIC_API_KEY" 'ANTHROPIC_API_KEY=""' \
  "$(cat "$SBX/claude-source/deepseek-claude")"
assert_contains "PATH persisted to environment.d" "$SBX/.local/bin" \
  "$(cat "$SBX/.config/environment.d/zim-claude.conf" 2>/dev/null)"
assert_contains "bashrc marker block added" "# >>> zim-claude >>>" \
  "$(cat "$SBX/.bashrc" 2>/dev/null)"

# The installed env file must decode to the same token as the repo blob.
want="$(tr -d ' \t\r\n' < "$REPO/config/token")"
got="$(sed -n 's/^export ANTHROPIC_AUTH_TOKEN="\(.*\)"$/\1/p' "$SBX/claude-source/deepseek-claude")"
assert_eq "installed token matches repo blob" "$want" "$got"

section "idempotency"

out="$(sbx_install 2>&1)"
assert_contains "second run reports unchanged" "unchanged: $SBX/.local/bin/zim-claude" "$out"
assert_contains "second run keeps env file" "keeping existing env file" "$out"
n="$(sbx_install --dry-run 2>&1 | grep -c 'would: install')"
assert_eq "dry-run after install performs 0 installs" "0" "$n"
n="$(grep -c 'zim-claude' "$SBX/.bashrc")"
assert_eq "bashrc marker not duplicated" "3" "$n"

section "secret is never clobbered"

# Save the good profile: this section deliberately corrupts it, and the
# wrapper tests below need a complete one back.
cp "$SBX/claude-source/deepseek-claude" "$SBX/good-profile"

printf 'export ANTHROPIC_AUTH_TOKEN="sentinel-must-survive"\n' > "$SBX/claude-source/deepseek-claude"
chmod 644 "$SBX/claude-source/deepseek-claude"
sbx_install >/dev/null 2>&1
assert_contains "token survives a re-install" "sentinel-must-survive" \
  "$(cat "$SBX/claude-source/deepseek-claude")"
assert_eq "re-install tightens env file to 600" "600" \
  "$(stat -c%a "$SBX/claude-source/deepseek-claude")"
sbx_install --force >/dev/null 2>&1
assert_contains "token survives --force" "sentinel-must-survive" \
  "$(cat "$SBX/claude-source/deepseek-claude")"

# Restore, so later sections test the wrapper against a real profile.
cp "$SBX/good-profile" "$SBX/claude-source/deepseek-claude"
chmod 600 "$SBX/claude-source/deepseek-claude"

section "Token Juice -> Logfare migration"

# A profile carried over from the old upstream holds a tj_ key. Logfare
# forwards it upstream and 401s every request, so leaving it alone would make
# a successful install fail on first use. It is the one credential the
# installer replaces - and it must take a backup first.
printf 'export ANTHROPIC_BASE_URL="http://localhost:4000"\n' > "$SBX/claude-source/deepseek-claude"
printf 'export ANTHROPIC_AUTH_TOKEN="tj_legacy-token"\n' >> "$SBX/claude-source/deepseek-claude"
printf 'export ANTHROPIC_MODEL="deepseek-v4.1-flash-1017"\n' >> "$SBX/claude-source/deepseek-claude"
out="$(sbx_install 2>&1)"
assert_contains "legacy tj_ profile is migrated" "migrating env file from Token Juice to Logfare" "$out"
assert_contains "migrated profile carries the Logfare token" \
  "lfu_cb4hVQ0yPUkv_PiugQ5onOIKdBqgiden" "$(cat "$SBX/claude-source/deepseek-claude")"
assert_contains "migrated profile drops the stale model name" \
  'ANTHROPIC_MODEL="deepseek-v4.1-flash"' "$(cat "$SBX/claude-source/deepseek-claude")"
if grep -q 'tj_legacy-token\|Flash-1017' "$SBX/claude-source/deepseek-claude"; then
  fail "migration leaves no Token Juice remnants" "old token or model survived"
else pass "migration leaves no Token Juice remnants"; fi
if compgen -G "$SBX/.local/share/zim-claude/backups/*/claude-source__deepseek-claude" >/dev/null; then
  pass "migration backs up the old profile"
else fail "migration backs up the old profile" "no backup of the tj_ profile found"; fi
assert_eq "migrated profile is mode 600" "600" \
  "$(stat -c%a "$SBX/claude-source/deepseek-claude" 2>/dev/null)"

# Restore the shipped profile for the wrapper tests below.
cp "$SBX/good-profile" "$SBX/claude-source/deepseek-claude"
chmod 600 "$SBX/claude-source/deepseek-claude"

# ---------------------------------------------------------------- wrapper ---

section "argument pass-through"

ZC="$SBX/.local/bin/zim-claude"
# stderr is dropped here (and asserted separately where it matters) so the
# wrapper's advisory warnings don't clutter the test log.
run_stub() { env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 "$ZC" "$@" 2>/dev/null; }

out="$(run_stub)"
assert_eq "no args -> ARGC=0" "ARGC=0" "$(head -1 <<<"$out")"

out="$(run_stub --dangerously-skip-permissions)"
assert_eq "--dangerously-skip-permissions -> ARGC=1" "ARGC=1" "$(head -1 <<<"$out")"
assert_contains "  ...forwarded verbatim" "[1]=<--dangerously-skip-permissions>" "$out"

out="$(run_stub mcp add "my server" --command "npx -y foo bar")"
assert_eq "mcp add with spaces -> ARGC=5" "ARGC=5" "$(head -1 <<<"$out")"
assert_contains "  ...positional name with space preserved" "[3]=<my server>" "$out"
assert_contains "  ...embedded-space command preserved" "[5]=<npx -y foo bar>" "$out"

out="$(run_stub -- --not-a-flag)"
assert_eq "-- separator -> ARGC=2" "ARGC=2" "$(head -1 <<<"$out")"
assert_contains "  ...-- forwarded literally" "[1]=<-->" "$out"

out="$(run_stub "" x)"
assert_eq "empty string arg -> ARGC=2" "ARGC=2" "$(head -1 <<<"$out")"
assert_contains "  ...empty arg preserved" "[1]=<>" "$out"

out="$(run_stub "$(printf 'a\nb')" 'c"d')"
assert_eq "newline/quote args -> ARGC=2" "ARGC=2" "$(head -1 <<<"$out")"
assert_contains "  ...newline preserved" "[1]=<a" "$out"

out="$(run_stub mcp list)"
assert_eq "mcp list -> ARGC=2" "ARGC=2" "$(head -1 <<<"$out")"
assert_contains "  ...subcommand forwarded" "[1]=<mcp>" "$out"

section "environment handling"

out="$(run_stub --version)"
assert_contains "profile base url reaches claude" "BASE_URL=http://localhost:4000" "$out"
assert_contains "profile model reaches claude" "MODEL=deepseek-v4.1-flash" "$out"
assert_contains "auth token exported" "TOKEN_SET=yes" "$out"
assert_contains "ANTHROPIC_API_KEY is empty" "APIKEY=<>" "$out"

# The regression test for the competing provider in ~/.bashrc.
out="$(env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 \
  ANTHROPIC_BASE_URL="https://cavoti.com/" "$ZC" --version 2>/dev/null)"
assert_contains "inherited base url is overridden" "BASE_URL=http://localhost:4000" "$out"

err="$(env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 \
  ANTHROPIC_BASE_URL="https://cavoti.com/" "$ZC" --version 2>&1 >/dev/null)"
assert_contains "override is reported on stderr" "overriding inherited ANTHROPIC_BASE_URL" "$err"

out="$(env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 \
  ANTHROPIC_API_KEY="sk-a-real-looking-key" "$ZC" --version 2>/dev/null)"
assert_contains "inherited API key is cleared" "APIKEY=<>" "$out"

# set -a must not leak: only names the profile assigns are touched.
out="$(env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 \
  ZIM_TEST_UNRELATED="untouched" "$ZC" --version 2>/dev/null)"
assert_contains "unrelated env var survives" "UNRELATED=untouched" "$out"

out="$(env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 ZIM_TEST_CHECK_FDS=1 "$ZC" --version 2>/dev/null)"
assert_contains "no flock fd leaks into claude" "FD_LEAK=no" "$out"

section "fail-closed behaviour"

# Missing profile must be fatal: falling through would run against whatever
# provider the user's shell already exports.
env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 \
  LITELLM_ENV_FILE=/nonexistent "$ZC" --version >/dev/null 2>&1
assert_eq "missing env file exits 2" "2" "$?"

err="$(env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 \
  LITELLM_ENV_FILE=/nonexistent "$ZC" --version 2>&1 >/dev/null)"
assert_contains "missing env file explains why" "Refusing to run" "$err"

printf 'export FOO=1\n' > "$SBX/bad-profile"
env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 \
  LITELLM_ENV_FILE="$SBX/bad-profile" "$ZC" --version >/dev/null 2>&1
assert_eq "profile without a token exits 2" "2" "$?"

env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN=/nonexistent/claude ZIM_CLAUDE_NO_PROXY=1 "$ZC" --version >/dev/null 2>&1
assert_eq "missing claude binary exits 2" "2" "$?"

# A non-zero exit from claude must pass through untouched, not become 2.
cat > "$SBX/stub-fail" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$SBX/stub-fail"
env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$SBX/stub-fail" ZIM_CLAUDE_NO_PROXY=1 "$ZC" >/dev/null 2>&1
assert_eq "claude's exit code passes through" "42" "$?"

section "stdout hygiene"

out="$(env -i HOME="$SBX" PATH="/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_PROXY=1 \
  ANTHROPIC_BASE_URL="https://cavoti.com/" "$ZC" --version 2>/dev/null)"
assert_contains "stub output reaches stdout" "ARGC=1" "$out"
if [[ "$out" == *"overriding"* ]]; then fail "warnings stay off stdout" "found warning on stdout"
else pass "warnings stay off stdout (clean)"; fi

section "clean install with prerequisites present"

# Same sandbox, but with claude and litellm reachable, so the installer should
# report success rather than a prereq failure.
PREREQ_SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-prereq-XXXXXX")"
mkdir -p "$PREREQ_SBX/bin"
ln -sf "$STUB" "$PREREQ_SBX/bin/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PREREQ_SBX/bin/litellm"
chmod +x "$PREREQ_SBX/bin/litellm"
env -i HOME="$PREREQ_SBX" PATH="$PREREQ_SBX/bin:/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" </dev/null >/dev/null 2>&1
assert_eq "installer exits 0 when prereqs present" "0" "$?"
[[ -x "$PREREQ_SBX/.local/bin/zim-claude" ]] && pass "wrapper installed in clean sandbox" \
  || fail "wrapper installed in clean sandbox"

# litellm is already on PATH here, so the installer must REUSE it and build
# nothing. Duplicating it into a venv would download litellm's whole dependency
# tree for a user who already had one.
[[ -e "$PREREQ_SBX/.local/share/zim-claude/venv" ]] \
  && fail "existing litellm is reused, not duplicated" "installer built a venv anyway" \
  || pass "existing litellm is reused, not duplicated"
rm -rf "$PREREQ_SBX"

section "uninstall"

echo "# hand edit" >> "$SBX/.local/bin/zim-claude"
sbx_install --uninstall >/dev/null 2>&1
[[ -e "$SBX/.local/bin/zim-claude" ]] && pass "modified file left in place" \
  || fail "modified file left in place"
[[ -e "$SBX/.local/bin/start-litellm.sh" ]] && fail "unmodified file removed" \
  || pass "unmodified file removed"
[[ -e "$SBX/claude-source/deepseek-claude" ]] && pass "user credential preserved" \
  || fail "user credential preserved"
n="$(grep -c 'zim-claude' "$SBX/.bashrc" 2>/dev/null || true)"
assert_eq "bashrc marker removed" "0" "$n"
[[ -e "$SBX/.config/environment.d/zim-claude.conf" ]] && fail "environment.d entry removed" \
  || pass "environment.d entry removed"

# ------------------------------------------------------- proxy venv -------

section "proxy virtualenv"

# No litellm anywhere, and no terminal: the installer must still finish (the
# CLI half is fine) rather than blocking on a prompt or downloading litellm
# unasked. This is the `curl | bash` path, and the one that used to advise
# `pip install --break-system-packages`.
VENV_SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-venv-XXXXXX")"
out="$(env -i HOME="$VENV_SBX" PATH="/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" </dev/null 2>&1)"
assert_eq "no-litellm install still exits 1 for prereqs" "1" "$?"
assert_contains "installer reports it skipped the venv" "skipping the proxy virtualenv" "$out"
assert_contains "installer says the proxy has no litellm" "no litellm to run" "$out"
[[ -x "$VENV_SBX/.local/bin/zim-claude" ]] && pass "wrapper still installed without a venv" \
  || fail "wrapper still installed without a venv"
[[ -e "$VENV_SBX/.local/share/zim-claude/venv" ]] \
  && fail "no venv built without consent" "installer built one unprompted" \
  || pass "no venv built without consent"

# --no-venv must never even offer to build one.
out="$(env -i HOME="$VENV_SBX" PATH="/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" --no-venv </dev/null 2>&1)"
assert_contains "--no-venv reports the venv as disabled" "proxy virtualenv disabled" "$out"

# Debian/Ubuntu ship python3 without the venv module. That is the one case the
# venv approach cannot paper over, so it must be detected and named rather than
# surfacing as a raw traceback. A stub python3 whose `-m venv --help` fails
# reproduces it without needing a Debian box.
NOVENV_SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-novenv-XXXXXX")"
mkdir -p "$NOVENV_SBX/bin"
printf '#!/bin/sh\ncase "$*" in *"venv --help"*) exit 1;; *) exit 0;; esac\n' \
  > "$NOVENV_SBX/bin/python3"
chmod +x "$NOVENV_SBX/bin/python3"
ln -sf "$STUB" "$NOVENV_SBX/bin/claude"
out="$(env -i HOME="$NOVENV_SBX" PATH="$NOVENV_SBX/bin:/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" </dev/null 2>&1)"
assert_contains "venv-less python3 is reported, not crashed on" \
  "has no venv module" "$out"
assert_contains "venv-less python3 names the fix" "python3-venv" "$out"
[[ -x "$NOVENV_SBX/.local/bin/zim-claude" ]] \
  && pass "CLI still installs when the venv cannot be built" \
  || fail "CLI still installs when the venv cannot be built"
rm -rf "$NOVENV_SBX"

# A venv that already has litellm is left completely alone — re-running the
# installer must not rebuild it. The stub is enough: the installer only checks
# that bin/litellm is executable.
mkdir -p "$VENV_SBX/.local/share/zim-claude/venv/bin"
printf '#!/bin/sh\nexit 0\n' > "$VENV_SBX/.local/share/zim-claude/venv/bin/litellm"
chmod +x "$VENV_SBX/.local/share/zim-claude/venv/bin/litellm"
printf '%s\n' 'litellm[proxy]>=1.100.1 uvloop>=0.22.1' \
  > "$VENV_SBX/.local/share/zim-claude/venv/.litellm-req"
out="$(env -i HOME="$VENV_SBX" PATH="/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" </dev/null 2>&1)"
assert_contains "existing venv is found, not rebuilt" "existing virtualenv" "$out"
# This sandbox has no `claude`, so the install still exits 1 for that reason —
# what matters here is that the venv no longer counts as a missing prerequisite.
if [[ "$out" == *"litellm not found"* ]]; then
  fail "a found venv satisfies the litellm prerequisite" "installer still reported litellm missing"
else
  pass "a found venv satisfies the litellm prerequisite"
fi

# start-litellm.sh must actually FIND that venv with no litellm on PATH — the
# whole point of the change. --help short-circuits before any proxy work, so
# this is safe to run with a stub binary.
resolved="$(env -i HOME="$VENV_SBX" PATH="/usr/bin:/bin" TERM=dumb bash -c '
  set -euo pipefail
  LITELLM_BIN=""
  [[ -n "$LITELLM_BIN" ]] || LITELLM_BIN="$(command -v litellm 2>/dev/null || true)"
  if [[ -z "$LITELLM_BIN" ]]; then
    for _c in "$HOME/.local/bin/litellm" \
              "${ZIM_CLAUDE_VENV:-$HOME/.local/share/zim-claude/venv}/bin/litellm"; do
      [[ -x "$_c" ]] && LITELLM_BIN="$_c" && break
    done
  fi
  printf "%s" "$LITELLM_BIN"')"
assert_eq "proxy resolves the venv litellm when nothing is on PATH" \
  "$VENV_SBX/.local/share/zim-claude/venv/bin/litellm" "$resolved"

# The stamp is the ownership marker --uninstall keys on. A venv carrying it is
# ours and goes; the credential beside it still must not.
env -i HOME="$VENV_SBX" PATH="/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" --uninstall </dev/null >/dev/null 2>&1
[[ -e "$VENV_SBX/.local/share/zim-claude/venv" ]] \
  && fail "uninstall removes the venv it built" "venv still present" \
  || pass "uninstall removes the venv it built"
[[ -e "$VENV_SBX/claude-source/deepseek-claude" ]] && pass "uninstall still preserves the credential" \
  || fail "uninstall still preserves the credential"

# A venv WITHOUT the stamp was made by the user, not by us, and must survive.
mkdir -p "$VENV_SBX/.local/share/zim-claude/venv/bin"
printf '#!/bin/sh\nexit 0\n' > "$VENV_SBX/.local/share/zim-claude/venv/bin/litellm"
chmod +x "$VENV_SBX/.local/share/zim-claude/venv/bin/litellm"
env -i HOME="$VENV_SBX" PATH="/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" --uninstall </dev/null >/dev/null 2>&1
[[ -e "$VENV_SBX/.local/share/zim-claude/venv" ]] \
  && pass "uninstall keeps a venv it did not build" \
  || fail "uninstall keeps a venv it did not build"
rm -rf "$VENV_SBX"

# ---------------------------------------------------------------- summary ---

printf '\n%s== summary%s\n' "$c_b" "$c_0"
printf '  %spassed: %d%s\n' "$c_g" "$PASS" "$c_0"
(( FAIL )) && printf '  %sfailed: %d%s\n' "$c_r" "$FAIL" "$c_0"
(( SKIP )) && printf '  %sskipped: %d%s\n' "$c_y" "$SKIP" "$c_0"
printf '\n'

(( FAIL )) && exit 1
exit 0
