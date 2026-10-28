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

# assert_lacks <label> <needle> <haystack>
assert_lacks() {
  if [[ "$3" != *"$2"* ]]; then pass "$1"
  else fail "$1" "did not expect to find: $(printf '%q' "$2")"; fi
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

# The live model-name configuration lives outside the repo, in ~/tokenjuice/,
# and belongs to whoever put it there — install.sh only creates it when it is
# missing. What must hold is that the installer and the proxy agree on the
# directory and on the model name. The wrapper is deliberately absent from this
# check: it no longer touches ~/tokenjuice/ at all.
if grep -qF 'TOKENJUICE_DIR="${ZIM_CLAUDE_TOKENJUICE_DIR:-$HOME/tokenjuice}"' "$REPO/install.sh" &&
   grep -qF 'CONFIG="${LITELLM_CONFIG:-$TOKENJUICE_DIR/litellm-config.yaml}"' "$REPO/scripts/start-litellm.sh" &&
   grep -qF 'ENV_FILE="${LITELLM_ENV_FILE:-$TOKENJUICE_DIR/source}"' "$REPO/scripts/start-litellm.sh"; then
  pass "installer and proxy agree on ~/tokenjuice"
else
  fail "installer and proxy disagree on ~/tokenjuice" \
       "install.sh and scripts/start-litellm.sh must name the same directory"
fi

if grep -qF 'api_base: https://api.tokenjuice.ai/v1' "$REPO/config/litellm-config.yaml" &&
   grep -qF 'model_name: deepseek-v4.1-flash-1017' "$REPO/config/litellm-config.yaml"; then
  pass "shipped config targets Token Juice under the profile's model name"
else fail "shipped config does not target Token Juice" \
       "expected api.tokenjuice.ai and model_name deepseek-v4.1-flash-1017"; fi

if grep -qF 'PROFILE_MODEL="${ZIM_CLAUDE_MODEL:-deepseek-v4.1-flash-1017}"' "$REPO/install.sh"; then
  pass "installer's profile model matches the shipped config"
else fail "installer's profile model drifts from the shipped config"; fi

if grep -qF 'api_base: https://api.tokenjuice.ai/v1' "$REPO/claude-desktop-integration/litellm-config.desktop.yaml"; then
  pass "desktop gateway config targets Token Juice too"
else fail "desktop gateway config still points somewhere else"; fi

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

# The public Token Juice key stays in the tree — it is public by design — but
# it must not be loaded anywhere any more: the unlimited quota ended and
# zim-claude routes to TokenHarbor. Any OTHER live-looking key is still a leak.
if [[ -f "$REPO/config/token" ]] && \
   grep -qxE 'tj_[A-Za-z0-9_-]{16,}' "$REPO/config/token"; then
  pass "the public key still ships in config/token"
else fail "the public key still ships in config/token" "config/token is missing or malformed"; fi

# Nothing may READ it back: not the installer, not the wrapper, not the Windows
# port. That is the whole point of the change. (Prose about it is fine; a load
# is not, so match the two read idioms rather than the string.)
if grep -qF '<"$SRC_DIR/config/token"' "$REPO/install.sh" ||
   grep -qF "config\\token" "$REPO/windows/win-install.ps1"; then
  fail "no installer loads the shipped key" "a config/token read survived"
else
  pass "no installer loads the shipped key"
fi
if grep -qF 'config/token' "$REPO/scripts/zim-claude" ||
   grep -qF 'config\token' "$REPO/windows/zim-claude.ps1"; then
  fail "the wrapper never mentions the shipped key" "the wrapper would read it again"
else
  pass "the wrapper never mentions the shipped key"
fi

if hits="$(grep -rnE '(tj|lfu|thk)_[A-Za-z0-9_-]{16,}' "$REPO" \
             --exclude-dir=.git --exclude-dir=tests 2>/dev/null \
             | grep -v "^$REPO/config/token:")"; then
  fail "no other live API key is committed" "$hits"
else pass "no other live API key is committed"; fi

# Token Juice is down; the wrapper runs against TokenHarbor and says so on
# every run until the user has a key of their own.
if grep -qF 'https://tokenharbor.ai' "$REPO/scripts/zim-claude" &&
   grep -qF 'unlimited quota ended' "$REPO/scripts/zim-claude" &&
   grep -qF 'ZIM_CLAUDE_USE_TOKENHARBOR' "$REPO/scripts/zim-claude"; then
  pass "the wrapper targets TokenHarbor and carries the outage notice"
else
  fail "the wrapper targets TokenHarbor and carries the outage notice" \
       "expected https://tokenharbor.ai, 'unlimited quota ended' and ZIM_CLAUDE_USE_TOKENHARBOR"
fi

# ------------------------------------------------------------- windows ------

section "windows artifacts"

# The Windows port is PowerShell, which this Linux box cannot execute (no pwsh).
# What IS checkable here is that the files exist and that the shims point at the
# right targets: a .bat wired to a renamed .ps1 is a silent, total failure that
# no amount of review would catch, and it is exactly what a rename would break.
for f in win-install.bat win-install.ps1 zim-claude.cmd zim-claude.ps1 \
         start-proxies.ps1 verify.ps1 zim-claude-update.ps1; do
  if [[ -f "$REPO/windows/$f" ]]; then pass "windows/$f present"
  else fail "windows/$f present"; fi
done

# The Linux updater must ship and be executable: the wrapper only launches it
# when it is, so a non-executable copy would silently disable auto-update.
if [[ -x "$REPO/scripts/zim-claude-update.sh" ]]; then
  pass "scripts/zim-claude-update.sh is executable"
else
  fail "scripts/zim-claude-update.sh is not executable" \
       "the wrapper would skip it and auto-update would never run"
fi

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
  fail "zim-claude.ps1 no longer manages the proxy" \
       "the wrapper must not start the Token Juice proxy any more"
else
  pass "zim-claude.ps1 no longer manages the proxy"
fi

# The Windows wrapper carries the same outage notice and opt-in as the bash one,
# and must not read the Token Juice profile or the shipped key.
if grep -qF 'unlimited quota ended' "$REPO/windows/zim-claude.ps1" &&
   grep -qF 'ZIM_CLAUDE_USE_TOKENHARBOR' "$REPO/windows/zim-claude.ps1" &&
   grep -qF 'https://tokenharbor.ai' "$REPO/windows/zim-claude.ps1"; then
  pass "zim-claude.ps1 carries the outage notice and the TokenHarbor opt-in"
else
  fail "zim-claude.ps1 carries the outage notice and the TokenHarbor opt-in" \
       "expected the notice, ZIM_CLAUDE_USE_TOKENHARBOR and https://tokenharbor.ai"
fi
if grep -qF 'tokenjuice\source' "$REPO/windows/zim-claude.ps1" 2>/dev/null ||
   grep -qF 'LITELLM_ENV_FILE' "$REPO/windows/zim-claude.ps1" 2>/dev/null; then
  fail "zim-claude.ps1 does not read the Token Juice profile" \
       "the wrapper still parses the LiteLLM-era profile"
else
  pass "zim-claude.ps1 does not read the Token Juice profile"
fi

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
# The .bat shims need CRLF; the bash side needs LF; nothing here holds a
# credential any more (the key lives in ~/tokenjuice/source, mode 600).
if [[ -f "$REPO/.gitattributes" ]]; then
  pass ".gitattributes present"
  if grep -qE '^[[:space:]]*config/token' "$REPO/.gitattributes"; then
    fail ".gitattributes still pins a credential file" "config/token is no longer tracked"
  else pass ".gitattributes carries no credential rule"; fi
  if grep -qE '^[[:space:]]*\*\.bat[[:space:]]+text[[:space:]]+eol=crlf' "$REPO/.gitattributes"; then
    pass ".gitattributes gives *.bat CRLF"
  else fail ".gitattributes does not set *.bat eol=crlf"; fi
else
  fail ".gitattributes present" "a Windows checkout with autocrlf=true would corrupt the bash scripts"
fi

# ---------------------------------------------------------------- sandbox ---

SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-XXXXXX")"
trap 'rm -rf "$SBX"' EXIT

# The installer probes localhost for a usable proxy port. Probing the REAL
# ports would make every assertion depend on whatever proxies this machine
# happens to be running, so the sandbox gets a stub curl that answers from
# ZIM_TEST_BUSY / ZIM_TEST_ACCEPT instead of the network.
#
#   busy   : health 200, /v1/models 400  (a proxy with a different master key)
#   accept : health 200, /v1/models 200  (a proxy that takes our token)
#   other  : 000                         (nothing listening)
STUB_BIN="$SBX/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
port=""
health=0
for a in "$@"; do
  case "$a" in
    http://127.0.0.1:*) port="${a#http://127.0.0.1:}"; port="${port%%/*}" ;;
    */health/liveliness) health=1 ;;
  esac
done
status=000
case " ${ZIM_TEST_BUSY:-} " in *" $port "*) status=400 ;; esac
case " ${ZIM_TEST_ACCEPT:-} " in *" $port "*) status=200 ;; esac
if (( health )) && [[ -n "$port" ]]; then
  case " ${ZIM_TEST_BUSY:-} ${ZIM_TEST_ACCEPT:-} " in *" $port "*) status=200 ;; esac
fi
printf '%s' "$status"
EOF
chmod +x "$STUB_BIN/curl"

# Run the installer with a HOME that has no ~/.local/bin on PATH, which also
# exercises the PATH-not-set branch. ZIM_CLAUDE_TOKEN is the scripted way to get
# a profile; the shipped config/token is deliberately not a credential source.
SBX_TOKEN="tj_sandbox000000000000000000000000"
sbx_install() {
  env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
    ZIM_CLAUDE_TOKEN="${ZIM_CLAUDE_TOKEN-$SBX_TOKEN}" \
    ZIM_TEST_BUSY="${ZIM_TEST_BUSY:-}" ZIM_TEST_ACCEPT="${ZIM_TEST_ACCEPT:-}" \
    bash "$REPO/install.sh" "$@" </dev/null
}

section "install into sandbox \$HOME"

sbx_install >/dev/null 2>&1
# Exit 1 is expected here: the sandbox PATH deliberately omits claude and
# litellm, so the installer reports missing prerequisites. Files still land.
assert_eq "installer reports missing prereqs as exit 1" "1" "$?"
[[ -x "$SBX/.local/bin/zim-claude" ]] && pass "wrapper installed" || fail "wrapper installed"
[[ -x "$SBX/.local/bin/start-litellm.sh" ]] && pass "start-litellm.sh installed" || fail "start-litellm.sh installed"
[[ -f "$SBX/tokenjuice/litellm-config.yaml" ]] && pass "model config created in ~/tokenjuice" \
  || fail "model config created in ~/tokenjuice"
[[ -f "$SBX/tokenjuice/source" ]] && pass "profile created in ~/tokenjuice" || fail "profile created in ~/tokenjuice"
[[ -e "$SBX/litellm-config.yaml" ]] && fail "no config left at ~/litellm-config.yaml" "old layout came back" \
  || pass "no config left at ~/litellm-config.yaml"
[[ -e "$SBX/claude-source" ]] && fail "no profile left at ~/claude-source" "old layout came back" \
  || pass "no profile left at ~/claude-source"

assert_eq "profile mode 600" "600" "$(stat -c%a "$SBX/tokenjuice/source" 2>/dev/null)"
assert_eq "tokenjuice dir mode 700" "700" "$(stat -c%a "$SBX/tokenjuice" 2>/dev/null)"
assert_eq "wrapper mode 755" "755" "$(stat -c%a "$SBX/.local/bin/zim-claude" 2>/dev/null)"
assert_eq "state dir mode 700" "700" "$(stat -c%a "$SBX/.local/share/zim-claude" 2>/dev/null)"

assert_contains "profile has base url on the Token Juice port" 'ANTHROPIC_BASE_URL="http://localhost:4000"' \
  "$(cat "$SBX/tokenjuice/source")"
assert_contains "profile clears ANTHROPIC_API_KEY" 'ANTHROPIC_API_KEY=""' \
  "$(cat "$SBX/tokenjuice/source")"
assert_contains "profile names the Token Juice model" 'ANTHROPIC_MODEL="deepseek-v4.1-flash-1017"' \
  "$(cat "$SBX/tokenjuice/source")"
assert_contains "PATH persisted to environment.d" "$SBX/.local/bin" \
  "$(cat "$SBX/.config/environment.d/zim-claude.conf" 2>/dev/null)"
assert_contains "bashrc marker block added" "# >>> zim-claude >>>" \
  "$(cat "$SBX/.bashrc" 2>/dev/null)"

# ZIM_CLAUDE_TOKEN wins over the public key that ships in config/token.
got="$(sed -n 's/^export ANTHROPIC_AUTH_TOKEN="\(.*\)"$/\1/p' "$SBX/tokenjuice/source")"
assert_eq "installed token is the one that was supplied" "$SBX_TOKEN" "$got"

# The shipped template must have landed byte-for-byte on a first install.
if cmp -s "$REPO/config/litellm-config.yaml" "$SBX/tokenjuice/litellm-config.yaml"; then
  pass "first install copies the shipped model config verbatim"
else fail "first install copies the shipped model config verbatim" "the two files differ"; fi

section "idempotency"

out="$(sbx_install 2>&1)"
assert_contains "second run reports unchanged" "unchanged: $SBX/.local/bin/zim-claude" "$out"
assert_contains "second run keeps env file" "keeping existing env file" "$out"
n="$(sbx_install --dry-run 2>&1 | grep -c 'would: install')"
assert_eq "dry-run after install performs 0 installs" "0" "$n"
n="$(grep -c 'zim-claude' "$SBX/.bashrc")"
assert_eq "bashrc marker not duplicated" "3" "$n"

# record_state appends a row per install, so a file installed more than once
# has duplicate rows. recorded_hash must use the newest, or every later run
# reports the file as user-modified and stops updating it.
sbx_install --force >/dev/null 2>&1
out="$(sbx_install 2>&1)"
if [[ "$out" == *"you have modified this file"* ]]; then
  fail "repeated installs keep recognising their own files" \
       "the state file's duplicate rows broke the hash comparison"
else
  pass "repeated installs keep recognising their own files"
fi

section "secret is never clobbered"

# Save the good profile: this section deliberately corrupts it, and the
# wrapper tests below need a complete one back.
cp "$SBX/tokenjuice/source" "$SBX/good-profile"

printf 'export ANTHROPIC_AUTH_TOKEN="sentinel-must-survive"\n' > "$SBX/tokenjuice/source"
chmod 644 "$SBX/tokenjuice/source"
sbx_install >/dev/null 2>&1
assert_contains "token survives a re-install" "sentinel-must-survive" \
  "$(cat "$SBX/tokenjuice/source")"
assert_eq "re-install tightens the profile to 600" "600" \
  "$(stat -c%a "$SBX/tokenjuice/source")"
sbx_install --force >/dev/null 2>&1
assert_contains "token survives --force" "sentinel-must-survive" \
  "$(cat "$SBX/tokenjuice/source")"

# Restore, so later sections test the wrapper against a real profile.
cp "$SBX/good-profile" "$SBX/tokenjuice/source"
chmod 600 "$SBX/tokenjuice/source"

section "the shared model config is never rewritten"

# ~/tokenjuice/litellm-config.yaml belongs to whoever put it there: other
# harnesses on the box drive the same route, so install.sh only ever creates a
# missing one. A config with hand-edited model names must survive - even --force.
cat > "$SBX/tokenjuice/litellm-config.yaml" <<'EOF'
# hand-written by the operator
model_list:
  - model_name: my-own-alias
    litellm_params:
      model: openai/some-upstream-model
      api_base: https://api.tokenjuice.ai/v1
      api_key: os.environ/ANTHROPIC_AUTH_TOKEN
EOF
before="$(sha256sum "$SBX/tokenjuice/litellm-config.yaml" | cut -d' ' -f1)"
out="$(sbx_install 2>&1)"
assert_contains "an existing model config is used, not replaced" \
  "using the model configuration already in place" "$out"
sbx_install --force >/dev/null 2>&1
after="$(sha256sum "$SBX/tokenjuice/litellm-config.yaml" | cut -d' ' -f1)"
assert_eq "the model config is untouched even by --force" "$before" "$after"

# Put the shipped one back for the sections that follow.
cp "$REPO/config/litellm-config.yaml" "$SBX/tokenjuice/litellm-config.yaml"

section "a foreign key is kept and reported"

# Nothing in the repo can replace a key it did not issue, so a profile carrying
# someone else's credential is kept - and said out loud, because Token Juice
# will reject it.
printf 'export ANTHROPIC_BASE_URL="http://localhost:4000"\n' > "$SBX/tokenjuice/source"
printf 'export ANTHROPIC_AUTH_TOKEN="sk-someone-elses-key"\n' >> "$SBX/tokenjuice/source"
printf 'export ANTHROPIC_MODEL="deepseek-v4.1-flash-1017"\n' >> "$SBX/tokenjuice/source"
out="$(sbx_install 2>&1)"
assert_contains "a foreign key is kept" "sk-someone-elses-key" "$(cat "$SBX/tokenjuice/source")"
assert_contains "a foreign key is reported as not a Token Juice key" \
  "does not look like a Token Juice key" "$out"
assert_contains "the profile is reported as kept" "keeping existing env file" "$out"

# A profile aimed at another provider is the user's own: never rewritten.
printf 'export ANTHROPIC_BASE_URL="https://api.example-provider.test/v1"\n' > "$SBX/tokenjuice/source"
printf 'export ANTHROPIC_AUTH_TOKEN="their-key"\n' >> "$SBX/tokenjuice/source"
out="$(sbx_install 2>&1)"
assert_contains "a profile aimed elsewhere keeps its key" "their-key" \
  "$(cat "$SBX/tokenjuice/source")"
assert_contains "a profile aimed elsewhere is reported as kept" \
  "keeping existing env file" "$out"
assert_eq "a kept profile is mode 600" "600" \
  "$(stat -c%a "$SBX/tokenjuice/source" 2>/dev/null)"

section "a fresh install does not load the shipped key"

# The public key still ships in config/token (it is public by design), but the
# unlimited quota ended: nothing may load it any more. With no profile, no
# terminal and no ZIM_CLAUDE_TOKEN, the installer must skip the credential and
# carry on — the wrapper offers TokenHarbor instead.
AUTOKEY_SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-autokey-XXXXXX")"
out="$(env -i HOME="$AUTOKEY_SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" </dev/null 2>&1)"
assert_contains "the shipped key is not used" "skipping the profile" "$out"
assert_contains "the outage is named" "Token Juice is down" "$out"
[[ -e "$AUTOKEY_SBX/tokenjuice/source" ]] \
  && fail "no profile is invented from config/token" "a profile was written" \
  || pass "no profile is invented from config/token"
[[ -x "$AUTOKEY_SBX/.local/bin/zim-claude" ]] && pass "CLI installs without being asked" \
  || fail "CLI installs without being asked"
rm -rf "$AUTOKEY_SBX"

section "a missing key is not an error"

# A machine with no key at all is the normal case now. The install must not
# fail, must not invent a profile, and must leave a usable CLI behind — the
# background auto-updater runs exactly this path with stdin closed.
NOKEY_SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-nokey-XXXXXX")"
out="$(env -i HOME="$NOKEY_SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" --no-venv --no-rc </dev/null 2>&1)"
assert_contains "the missing key is explained, not fatal" "skipping the profile" "$out"
assert_contains "the fix for the proxy route is named" "ZIM_CLAUDE_TOKEN" "$out"
[[ -x "$NOKEY_SBX/.local/bin/zim-claude" ]] && pass "CLI installs without a key" \
  || fail "CLI installs without a key"
[[ -e "$NOKEY_SBX/tokenjuice/source" ]] && fail "no profile is invented" "an empty profile was written" \
  || pass "no profile is invented"
rm -rf "$NOKEY_SBX"

section "proxy port selection"

# :4000 held by a proxy that rejects the token is the failure this machine
# actually has: the profile says :4000, the proxy there answers every request
# with "No connected db.", and zim-claude looks broken while the real problem
# is the port. The installer must move the profile to a port that works.
printf 'export ANTHROPIC_BASE_URL="http://localhost:4000"\n' > "$SBX/tokenjuice/source"
printf 'export ANTHROPIC_AUTH_TOKEN="tj_cb4hVQ0yPUkv_PiugQ5onOIKdBqgiden"\n' >> "$SBX/tokenjuice/source"
printf 'export ANTHROPIC_MODEL="deepseek-v4.1-flash"\n' >> "$SBX/tokenjuice/source"
printf 'export ANTHROPIC_API_KEY=""\n' >> "$SBX/tokenjuice/source"
out="$(ZIM_TEST_BUSY="4000 4001 4002 4003" ZIM_TEST_ACCEPT="4005" sbx_install 2>&1)"
assert_contains "a proxy that rejects the token is reported" \
  "rejects the profile's token" "$out"
assert_contains "the profile follows a proxy that accepts it" \
  'ANTHROPIC_BASE_URL="http://localhost:4005"' "$(cat "$SBX/tokenjuice/source")"
assert_contains "the port move is explained" "moving the env profile to port :4005" "$out"
assert_contains "the credential is kept, not replaced" \
  "tj_cb4hVQ0yPUkv_PiugQ5onOIKdBqgiden" "$(cat "$SBX/tokenjuice/source")"
if compgen -G "$SBX/.local/share/zim-claude/backups/*/tokenjuice__source" >/dev/null; then
  pass "the port move backs up the profile"
else fail "the port move backs up the profile" "no backup found"; fi

# A free :4000 is fine: zim-claude starts its own proxy there.
printf 'export ANTHROPIC_BASE_URL="http://localhost:4000"\n' > "$SBX/tokenjuice/source"
printf 'export ANTHROPIC_AUTH_TOKEN="tj_cb4hVQ0yPUkv_PiugQ5onOIKdBqgiden"\n' >> "$SBX/tokenjuice/source"
out="$(sbx_install 2>&1)"
assert_contains "a free port is kept" "free — zim-claude will start the proxy there" "$out"
assert_contains "a free port leaves the profile alone" \
  'ANTHROPIC_BASE_URL="http://localhost:4000"' "$(cat "$SBX/tokenjuice/source")"

# --port overrides the search entirely, even when another port looks usable.
out="$(ZIM_TEST_ACCEPT="4000" sbx_install --port 4100 2>&1)"
assert_contains "--port is honoured" "proxy port: 4100 (--port)" "$out"

# A port already accepting the token is not moved.
printf 'export ANTHROPIC_BASE_URL="http://localhost:4000"\n' > "$SBX/tokenjuice/source"
printf 'export ANTHROPIC_AUTH_TOKEN="tj_cb4hVQ0yPUkv_PiugQ5onOIKdBqgiden"\n' >> "$SBX/tokenjuice/source"
out="$(ZIM_TEST_ACCEPT="4000" sbx_install 2>&1)"
assert_contains "a working port is reported as working" \
  "already accepting the profile's token" "$out"

section "shell rc migration"

# ~/.bashrc commonly holds the same four exports. A stale key aimed at the
# local proxy is a dead provider for plain `claude`, so it is rewritten - with
# a backup - and the retired model name goes with it.
cat > "$SBX/.bashrc" <<'EOF'
# user's own file
export EDITOR=vim
export ANTHROPIC_BASE_URL="http://localhost:4000"
export ANTHROPIC_AUTH_TOKEN="legacy-unissued-token"
export ANTHROPIC_MODEL="deepseek-v4.1-flash"
export ANTHROPIC_API_KEY=""
alias ll='ls -l'
EOF
out="$(sbx_install 2>&1)"
assert_contains "rc repair is announced" "replacing the stale key in $SBX/.bashrc" "$out"
assert_contains "rc carries the Token Juice key" \
  'export ANTHROPIC_AUTH_TOKEN="tj_cb4hVQ0yPUkv_PiugQ5onOIKdBqgiden"' "$(cat "$SBX/.bashrc")"
assert_contains "rc picks up the current model name" \
  'export ANTHROPIC_MODEL="deepseek-v4.1-flash-1017"' "$(cat "$SBX/.bashrc")"
assert_contains "rc keeps unrelated exports" "export EDITOR=vim" "$(cat "$SBX/.bashrc")"
assert_contains "rc keeps aliases" "alias ll='ls -l'" "$(cat "$SBX/.bashrc")"
assert_contains "rc keeps the PATH marker block" "# >>> zim-claude >>>" "$(cat "$SBX/.bashrc")"
if grep -q 'legacy-unissued-token\|ANTHROPIC_MODEL="deepseek-v4.1-flash"$' "$SBX/.bashrc"; then
  fail "rc repair leaves no stale remnants" "old token or model survived"
else pass "rc repair leaves no stale remnants"; fi
if compgen -G "$SBX/.local/share/zim-claude/backups/*/.bashrc" >/dev/null; then
  pass "rc repair backs up the file"
else fail "rc repair backs up the file" "no .bashrc backup found"; fi

# A profile aimed at another provider is the user's own: report it, never
# rewrite it.
printf 'export ANTHROPIC_BASE_URL="https://api.example-provider.test/v1"\n' > "$SBX/.bashrc"
printf 'export ANTHROPIC_AUTH_TOKEN="sk-someone-elses-key"\n' >> "$SBX/.bashrc"
out="$(sbx_install 2>&1)"
assert_contains "a foreign rc token is left alone" "sk-someone-elses-key" "$(cat "$SBX/.bashrc")"
assert_contains "a foreign rc token is still reported" \
  "exports ANTHROPIC_*" "$out"

# --no-rc must not touch the shell config at all, repair included.
printf 'export ANTHROPIC_BASE_URL="http://localhost:4000"\n' > "$SBX/.bashrc"
printf 'export ANTHROPIC_AUTH_TOKEN="legacy-unissued-token"\n' >> "$SBX/.bashrc"
out="$(sbx_install --no-rc 2>&1)"
assert_contains "--no-rc keeps the stale key" "legacy-unissued-token" "$(cat "$SBX/.bashrc")"
assert_contains "--no-rc says why" "left alone (--no-rc)" "$out"

# Restore the shipped profile for the wrapper tests below.
cp "$SBX/good-profile" "$SBX/tokenjuice/source"
chmod 600 "$SBX/tokenjuice/source"

# ---------------------------------------------------------------- wrapper ---

section "argument pass-through"

ZC="$SBX/.local/bin/zim-claude"

# The wrapper calls curl for /v1/models. A stub answers from ZC_STATUS /
# ZC_MODELS, so no test needs the network. It lives in its own bin dir: the
# installer's stub answers port probes with a bare status code and no body.
ZCURL="$SBX/zcbin"
mkdir -p "$ZCURL"
cat > "$ZCURL/curl" <<'EOF'
#!/usr/bin/env bash
# Test stub for curl. Deliberately avoids ${VAR:-{...}} defaults: bash ends
# such an expansion at the first unescaped '}', truncating a JSON default.
code="${ZC_STATUS:-200}"
body=""
if [[ "$code" == "200" ]]; then
  body="${ZC_MODELS}"
  if [[ -z "$body" ]]; then
    body='{"object":"list","data":[{"id":"claude-opus-5.5"},{"id":"deepseek-v4.1-flash:free"},{"id":"mimo-v2.6-flash:free"},{"id":"th-rudder"},{"id":"gpt-6-astra"}]}'
  fi
fi
printf '%s' "$body"
printf '\n%s' "$code"
EOF
chmod +x "$ZCURL/curl"

ZSTATE="$SBX/zstate"
# stderr is dropped here (and asserted separately where it matters) so the
# wrapper's advisory warnings don't clutter the test log. ZC_OPTIN defaults to
# 1 so these tests exercise the route without an interactive prompt.
run_zc() { env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY="${ZC_KEY-thk_live_TESTKEY}" \
  ZIM_CLAUDE_MODEL="${ZC_MODEL-deepseek-v4.1-flash:free}" \
  ZIM_CLAUDE_USE_TOKENHARBOR="${ZC_OPTIN-1}" \
  "$ZC" "$@" 2>/dev/null; }

out="$(run_zc)"
assert_eq "no args -> ARGC=0" "ARGC=0" "$(head -1 <<<"$out")"

out="$(run_zc --dangerously-skip-permissions)"
assert_eq "--dangerously-skip-permissions -> ARGC=1" "ARGC=1" "$(head -1 <<<"$out")"
assert_contains "  ...forwarded verbatim" "[1]=<--dangerously-skip-permissions>" "$out"

out="$(run_zc mcp add "my server" --command "npx -y foo bar")"
assert_eq "mcp add with spaces -> ARGC=5" "ARGC=5" "$(head -1 <<<"$out")"
assert_contains "  ...positional name with space preserved" "[3]=<my server>" "$out"
assert_contains "  ...embedded-space command preserved" "[5]=<npx -y foo bar>" "$out"

out="$(run_zc -- --not-a-flag)"
assert_eq "-- separator -> ARGC=2" "ARGC=2" "$(head -1 <<<"$out")"
assert_contains "  ...-- forwarded literally" "[1]=<-->" "$out"

out="$(run_zc "" x)"
assert_eq "empty string arg -> ARGC=2" "ARGC=2" "$(head -1 <<<"$out")"
assert_contains "  ...empty arg preserved" "[1]=<>" "$out"

out="$(run_zc "$(printf 'a\nb')" 'c"d')"
assert_eq "newline/quote args -> ARGC=2" "ARGC=2" "$(head -1 <<<"$out")"
assert_contains "  ...newline preserved" "[1]=<a" "$out"

out="$(run_zc mcp list)"
assert_eq "mcp list -> ARGC=2" "ARGC=2" "$(head -1 <<<"$out")"
assert_contains "  ...subcommand forwarded" "[1]=<mcp>" "$out"

section "environment handling"

out="$(run_zc --version)"
assert_contains "TokenHarbor base url reaches claude" "BASE_URL=https://tokenharbor.ai" "$out"
assert_contains "the chosen model reaches claude" "MODEL=deepseek-v4.1-flash:free" "$out"
assert_contains "auth token exported" "TOKEN_SET=yes" "$out"
assert_contains "ANTHROPIC_API_KEY is empty" "APIKEY=<>" "$out"
assert_contains "every Anthropic tier is pinned to the chosen model" \
  "TIERS=deepseek-v4.1-flash:free|deepseek-v4.1-flash:free|deepseek-v4.1-flash:free|deepseek-v4.1-flash:free" "$out"

# An inherited Token Juice route is the one thing this package must never pick
# back up: the proxy is gone from the wrapper, so the stale value is reported
# and replaced rather than followed.
out="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=deepseek-v4.1-flash:free \
  ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  ANTHROPIC_BASE_URL="https://api.tokenjuice.ai/v1" "$ZC" --version 2>/dev/null)"
assert_contains "an inherited Token Juice base url is not used" "BASE_URL=https://tokenharbor.ai" "$out"

err="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=deepseek-v4.1-flash:free \
  ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  ANTHROPIC_BASE_URL="https://api.tokenjuice.ai/v1" "$ZC" --version 2>&1 >/dev/null)"
assert_contains "the dropped Token Juice route is reported" \
  "ignoring inherited ANTHROPIC_BASE_URL" "$err"

out="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=deepseek-v4.1-flash:free \
  ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  ANTHROPIC_API_KEY="sk-a-real-looking-key" "$ZC" --version 2>/dev/null)"
assert_contains "inherited API key is cleared" "APIKEY=<>" "$out"

# set -a must not leak: only names the wrapper assigns are touched.
out="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=deepseek-v4.1-flash:free \
  ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  ZIM_TEST_UNRELATED="untouched" "$ZC" --version 2>/dev/null)"
assert_contains "unrelated env var survives" "UNRELATED=untouched" "$out"

section "the Token Juice notice"

NSTATE="$SBX/state-notice"
notice_zc() { env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$NSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  "$ZC" --version </dev/null; }

err="$(notice_zc 2>&1 >/dev/null)"
assert_eq "no key and no answer exits 2" "2" "$?"
assert_contains "the notice names Token Juice" "Token Juice is currently down" "$err"
assert_contains "the notice says the quota ended" "unlimited quota ended" "$err"
assert_contains "the notice points at the opt-in" "ZIM_CLAUDE_USE_TOKENHARBOR=1" "$err"

# The notice is a line on stderr, never a reason to block a working session:
# with a key configured there is nothing to report.
KSTATE="$SBX/state-keyed"
mkdir -p "$KSTATE"
printf 'thk_live_CACHED\n' > "$KSTATE/tokenharbor.key"
chmod 600 "$KSTATE/tokenharbor.key"
out="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$KSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_MODEL=deepseek-v4.1-flash:free ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  "$ZC" --version 2>/dev/null)"
assert_contains "a cached key is used without a prompt" "TOKEN_SET=yes" "$out"

err="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$KSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_MODEL=deepseek-v4.1-flash:free ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  "$ZC" --version 2>&1 >/dev/null)"
if [[ "$err" == *"Token Juice is currently down"* ]]; then
  fail "the notice stops once a key is configured" "still printed: $err"
else pass "the notice stops once a key is configured"; fi

# A key from the environment is the user's, not ours to keep on disk.
[[ -e "$ZSTATE/tokenharbor.key" ]] \
  && fail "an environment key is never cached" "$ZSTATE/tokenharbor.key exists" \
  || pass "an environment key is never cached"

section "the TokenHarbor opt-in"

# =1 skips the question and remembers the answer...
OSTATE="$SBX/state-optin"
out="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$OSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=deepseek-v4.1-flash:free \
  ZIM_CLAUDE_USE_TOKENHARBOR=1 "$ZC" --version 2>/dev/null)"
assert_contains "the opt-in runs against TokenHarbor" "BASE_URL=https://tokenharbor.ai" "$out"
assert_contains "the opt-in is remembered" "tokenharbor" "$(cat "$OSTATE/route" 2>/dev/null)"

# ...so the next run needs neither the variable nor a prompt.
out="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$OSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=deepseek-v4.1-flash:free \
  "$ZC" --version 2>/dev/null)"
assert_contains "a remembered opt-in needs no variable" "BASE_URL=https://tokenharbor.ai" "$out"

# =0 is a refusal: the wrapper must not fall through to anything.
err="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$OSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=deepseek-v4.1-flash:free \
  ZIM_CLAUDE_USE_TOKENHARBOR=0 "$ZC" --version 2>&1 >/dev/null)"
assert_eq "declining TokenHarbor exits 2" "2" "$?"
assert_contains "declining still reports the outage" "Token Juice is down" "$err"

section "wrapper: the free-model picker"

if command -v script >/dev/null 2>&1; then
  # zc_pty <stdin> <shell-snippet> [models-json]
  zc_pty() {
    printf '%s' "$1" | env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
      ZC_MODELS="${3:-}" ZC_STATUS="${4:-200}" \
      script -qec "$2" /dev/null 2>&1
  }

  # No key anywhere: the wrapper offers TokenHarbor, then asks for a key, then
  # offers the free models. The pty carries all three answers.
  out="$(zc_pty $'y\nthk_live_TYPED\n\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state-pty ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "the wrapper offers TokenHarbor" "Use TokenHarbor instead?" "$out"
  assert_contains "a yes asks for a key" "paste it here" "$out"
  assert_contains "the typed key is accepted" "TOKEN_SET=yes" "$out"
  assert_contains "free models are listed" "deepseek-v4.1-flash:free" "$out"
  assert_contains "a second free model is listed" "mimo-v2.6-flash:free" "$out"
  assert_contains "th-rudder counts as free" "th-rudder" "$out"
  assert_lacks "a paid model is not offered" "claude-opus-5.5" "$out"

  # Declining the offer leaves nothing to run against and says why.
  out="$(zc_pty $'n\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state-decline ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "declining explains there is nothing to run" "TokenHarbor was declined" "$out"

  # The second entry selects the second free model.
  out="$(zc_pty $'y\nthk_live_TYPED\n2\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state-pick2 ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "the second entry is selected" "MODEL=mimo-v2.6-flash:free" "$out"

  # A remembered choice becomes the default, so Enter is stable. The route and
  # the key are both remembered by now, so the empty line accepts the default.
  out="$(zc_pty $'\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state-pick2 ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "the last pick is remembered as the default" "select 1-3 [2]" "$out"

  # Nonsense is re-asked, not accepted.
  out="$(zc_pty $'9\n1\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state-pick2 ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "an out-of-range choice is rejected" "not a choice: 9" "$out"
  assert_contains "a valid choice still works after that" "MODEL=deepseek-v4.1-flash:free" "$out"

  # A catalog with no :free ids falls back to the whole list instead of
  # refusing to start.
  out="$(zc_pty $'\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state-nofree ZIM_CLAUDE_NO_UPDATE=1 ZIM_CLAUDE_USE_TOKENHARBOR=1 ZIM_CLAUDE_API_KEY=thk_live_TESTKEY $ZC --version" \
        '{"data":[{"id":"claude-opus-5.5"},{"id":"gpt-6-astra"}]}')"
  assert_contains "a catalog with no free route says so" "no free model is advertised" "$out"
  assert_contains "a catalog with no free route still offers models" "claude-opus-5.5" "$out"
else
  skip "script(1) not available — cannot drive the interactive prompts"
fi

# A pinned model skips the picker entirely.
out="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=mimo-v2.6-flash:free \
  ZIM_CLAUDE_USE_TOKENHARBOR=1 "$ZC" --version 2>/dev/null)"
assert_lacks "a pinned model skips the picker" "free models on" "$out"
assert_contains "a pinned model is used" "MODEL=mimo-v2.6-flash:free" "$out"

section "wrapper: Token Juice cannot come back"

# The shipped key is public and stays in the tree, but it must not be usable
# through zim-claude: Token Juice's unlimited quota ended.
TJ_KEY="$(tr -d ' \t\r\n' < "$REPO/config/token" 2>/dev/null || true)"
err="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY="$TJ_KEY" ZIM_CLAUDE_MODEL=x ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  "$ZC" --version 2>&1 >/dev/null)"
assert_eq "the shipped Token Juice key is refused" "2" "$?"
assert_contains "the refusal names the key type" "Token Juice key" "$err"

err="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=x ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  ZIM_CLAUDE_BASE_URL="https://api.tokenjuice.ai/v1" "$ZC" --version 2>&1 >/dev/null)"
assert_eq "pointing the base url at Token Juice is refused" "2" "$?"
assert_contains "the base url refusal names the quota" "unlimited quota ended" "$err"

# Nothing in the wrapper may read the Token Juice profile or the shipped key.
for needle in 'tokenjuice/source' 'config/token' 'LITELLM_ENV_FILE' 'ANTHROPIC_AUTH_TOKEN="$token"'; do
  if grep -qF -- "$needle" "$REPO/scripts/zim-claude"; then
    fail "the wrapper does not read Token Juice state" "found: $needle"
  else
    pass "the wrapper does not read Token Juice state ($needle)"
  fi
done

section "wrapper: failure modes"

err="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb ZC_STATUS=401 \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_BAD ZIM_CLAUDE_MODEL=x ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  "$ZC" --version 2>&1 >/dev/null)"
assert_eq "a rejected environment key exits 2" "2" "$?"
assert_contains "a rejected environment key says where to rotate" \
  "Rotate it at https://tokenharbor.ai/dashboard/api-keys" "$err"

err="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb ZC_STATUS=000 \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=x ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  "$ZC" --version 2>&1 >/dev/null)"
assert_eq "an unreachable API exits 2" "2" "$?"
assert_contains "an unreachable API names the host" "could not reach https://tokenharbor.ai" "$err"

err="$(env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb ZC_MODELS='{"data":[]}' \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  "$ZC" --version 2>&1 >/dev/null)"
assert_eq "an empty catalog exits 2" "2" "$?"
assert_contains "an empty catalog says so" "returned no model ids" "$err"

env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN=/nonexistent/claude ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  "$ZC" --version >/dev/null 2>&1
assert_eq "missing claude binary exits 2" "2" "$?"

# A non-zero exit from claude must pass through untouched, not become 2.
cat > "$SBX/stub-fail" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$SBX/stub-fail"
env -i HOME="$SBX" PATH="$ZCURL:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$SBX/stub-fail" ZIM_CLAUDE_STATE_DIR="$ZSTATE" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_API_KEY=thk_live_TESTKEY ZIM_CLAUDE_MODEL=x ZIM_CLAUDE_USE_TOKENHARBOR=1 \
  "$ZC" >/dev/null 2>&1
assert_eq "claude's exit code passes through" "42" "$?"

section "stdout hygiene"

out="$(run_zc --version)"
assert_contains "stub output reaches stdout" "ARGC=1" "$out"
if [[ "$out" == *"[zim-claude]"* ]]; then
  fail "diagnostics stay off stdout" "found a [zim-claude] line on stdout"
else pass "diagnostics stay off stdout (clean)"; fi

# Even the outage notice must not pollute stdout, or `-p ... | jq` breaks.
out="$(notice_zc 2>/dev/null)"
assert_eq "the notice does not reach stdout" "" "$out"

section "clean install with prerequisites present"

# Same sandbox, but with claude and litellm reachable, so the installer should
# report success rather than a prereq failure.
PREREQ_SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-prereq-XXXXXX")"
mkdir -p "$PREREQ_SBX/bin"
ln -sf "$STUB" "$PREREQ_SBX/bin/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PREREQ_SBX/bin/litellm"
chmod +x "$PREREQ_SBX/bin/litellm"
env -i HOME="$PREREQ_SBX" PATH="$PREREQ_SBX/bin:$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_TOKEN="$SBX_TOKEN" bash "$REPO/install.sh" </dev/null >/dev/null 2>&1
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

# The auto-updater installs with stdin closed and no terminal. That path must
# succeed on a machine with no Token Juice profile — otherwise every upgrade
# fails exactly where nobody is looking.
UPGRADE_SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-upgrade-XXXXXX")"
out="$(env -i HOME="$UPGRADE_SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" --no-venv --no-rc </dev/null 2>&1)"
assert_contains "an upgrade without a profile says it is skipping it" \
  "skipping the profile" "$out"
[[ -x "$UPGRADE_SBX/.local/bin/zim-claude" ]] \
  && pass "the upgrade path still installs the wrapper" \
  || fail "the upgrade path still installs the wrapper"
rm -rf "$UPGRADE_SBX"

section "uninstall"

echo "# hand edit" >> "$SBX/.local/bin/zim-claude"
sbx_install --uninstall >/dev/null 2>&1
[[ -e "$SBX/.local/bin/zim-claude" ]] && pass "modified file left in place" \
  || fail "modified file left in place"
[[ -e "$SBX/.local/bin/start-litellm.sh" ]] && fail "unmodified file removed" \
  || pass "unmodified file removed"
[[ -e "$SBX/tokenjuice/source" ]] && pass "user credential preserved" \
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
out="$(env -i HOME="$VENV_SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_TOKEN="$SBX_TOKEN" bash "$REPO/install.sh" </dev/null 2>&1)"
assert_eq "a no-claude sandbox still exits 1 for prereqs" "1" "$?"
assert_contains "installer reports it skipped the venv" "skipping the proxy virtualenv" "$out"
assert_contains "installer says the proxy has no litellm" "no litellm to run" "$out"
[[ -x "$VENV_SBX/.local/bin/zim-claude" ]] && pass "wrapper still installed without a venv" \
  || fail "wrapper still installed without a venv"
# With claude present, a missing litellm is a note, not a failed install: the
# proxy is optional now, and the background updater runs this exact path on
# machines that never had litellm.
NOLITELLM_SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-nolitellm-XXXXXX")"
mkdir -p "$NOLITELLM_SBX/bin"
ln -sf "$STUB" "$NOLITELLM_SBX/bin/claude"
env -i HOME="$NOLITELLM_SBX" PATH="$NOLITELLM_SBX/bin:/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" --no-venv --no-rc </dev/null >/dev/null 2>&1
assert_eq "a missing litellm does not fail the install" "0" "$?"
[[ -x "$NOLITELLM_SBX/.local/bin/zim-claude" ]] \
  && pass "the CLI is installed with no litellm" \
  || fail "the CLI is installed with no litellm"
rm -rf "$NOLITELLM_SBX"

[[ -e "$VENV_SBX/.local/share/zim-claude/venv" ]] \
  && fail "no venv built without consent" "installer built one unprompted" \
  || pass "no venv built without consent"

# --no-venv must never even offer to build one.
out="$(env -i HOME="$VENV_SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
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
out="$(env -i HOME="$VENV_SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_TOKEN="$SBX_TOKEN" bash "$REPO/install.sh" </dev/null 2>&1)"
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
env -i HOME="$VENV_SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" --uninstall </dev/null >/dev/null 2>&1
[[ -e "$VENV_SBX/.local/share/zim-claude/venv" ]] \
  && fail "uninstall removes the venv it built" "venv still present" \
  || pass "uninstall removes the venv it built"
[[ -e "$VENV_SBX/tokenjuice/source" ]] && pass "uninstall still preserves the credential" \
  || fail "uninstall still preserves the credential"

# A venv WITHOUT the stamp was made by the user, not by us, and must survive.
mkdir -p "$VENV_SBX/.local/share/zim-claude/venv/bin"
printf '#!/bin/sh\nexit 0\n' > "$VENV_SBX/.local/share/zim-claude/venv/bin/litellm"
chmod +x "$VENV_SBX/.local/share/zim-claude/venv/bin/litellm"
env -i HOME="$VENV_SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  bash "$REPO/install.sh" --uninstall </dev/null >/dev/null 2>&1
[[ -e "$VENV_SBX/.local/share/zim-claude/venv" ]] \
  && pass "uninstall keeps a venv it did not build" \
  || fail "uninstall keeps a venv it did not build"
rm -rf "$VENV_SBX"

# ------------------------------------------------------- auto-update ------

section "auto-update"

# A throwaway origin and clone. The updater only ever talks to whatever
# `origin` the checkout has, so a local bare repo exercises every path -
# fast-forward, up to date, dirty, diverged - without network access.
if ! command -v git >/dev/null 2>&1; then
  skip "git not installed - cannot exercise the updater"
else
  UP_SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-update-XXXXXX")"
  ORIGIN="$UP_SBX/origin.git"
  CLONE="$UP_SBX/clone"
  STATE="$UP_SBX/state"

  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
  git -C "$CLONE" config user.name "Test"
  git -C "$CLONE" config user.email "test@example.invalid"
  # Minimal checkout: the updater re-runs install.sh, so it must be present
  # and must succeed without touching the network or the real $HOME.
  cat > "$CLONE/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'installed %s\n' "$(cat "$(dirname "$0")/VERSION")" >> "${UPDATE_MARK:?}"
EOF
  chmod +x "$CLONE/install.sh"
  printf 'v1\n' > "$CLONE/VERSION"
  git -C "$CLONE" add -A
  git -C "$CLONE" commit -qm v1
  branch="$(git -C "$CLONE" symbolic-ref --short HEAD)"
  git -C "$CLONE" push -q origin "$branch"

  mkdir -p "$STATE"
  printf 'ZIM_CLAUDE_AUTO_UPDATE=1\nZIM_CLAUDE_REPO_DIR=%q\nZIM_CLAUDE_REPO_BRANCH=%q\n' \
    "$CLONE" "$branch" > "$STATE/update.conf"

  up() {
    env -i HOME="$UP_SBX" PATH="/usr/bin:/bin" TERM=dumb \
      UPDATE_MARK="$STATE/mark" \
      ZIM_CLAUDE_STATE_DIR="$STATE" ZIM_CLAUDE_UPDATE_CONF="$STATE/update.conf" \
      ZIM_CLAUDE_UPDATE_LOG="$STATE/update.log" \
      ZIM_CLAUDE_UPDATE_INTERVAL=0 \
      bash "$REPO/scripts/zim-claude-update.sh" "$@"
  }

  # 1. up to date: nothing is installed, but it still succeeds.
  up
  assert_eq "updater exits 0 when up to date" "0" "$?"
  assert_contains "updater reports up to date" "already up to date" \
    "$(cat "$STATE/update.log" 2>/dev/null)"

  # 2. a new upstream commit is fast-forwarded and installed.
  git -C "$CLONE" pull -q origin "$branch"
  printf 'v2\n' > "$CLONE/VERSION"
  git -C "$CLONE" commit -qam v2
  git -C "$CLONE" push -q origin "$branch"
  # Put the clone back one commit, so the updater has work to do.
  git -C "$CLONE" reset -q --hard HEAD~1
  up
  assert_contains "updater fast-forwards" "updated " "$(cat "$STATE/update.log")"
  assert_eq "fast-forward reaches the new commit" "v2" "$(cat "$CLONE/VERSION")"
  assert_contains "installer ran after the update" "installed v2" \
    "$(cat "$STATE/mark" 2>/dev/null)"

  # 3. a dirty checkout is left alone.
  printf 'local edit\n' >> "$CLONE/VERSION"
  before="$(git -C "$CLONE" rev-parse HEAD)"
  git -C "$CLONE" pull -q origin "$branch" >/dev/null 2>&1 || true
  up
  assert_contains "dirty checkout is not updated" "has local changes" \
    "$(cat "$STATE/update.log")"
  assert_eq "dirty checkout keeps its HEAD" "$before" "$(git -C "$CLONE" rev-parse HEAD)"
  git -C "$CLONE" checkout -q -- VERSION

  # 4. a diverged branch (local commit) is not merged or reset.
  printf 'local\n' > "$CLONE/LOCAL"
  git -C "$CLONE" add -A
  git -C "$CLONE" commit -qm local-only
  # Advance origin separately.
  other="$UP_SBX/other"
  git clone -q "$ORIGIN" "$other" 2>/dev/null
  git -C "$other" config user.name "Test"
  git -C "$other" config user.email "test@example.invalid"
  printf 'v3\n' > "$other/VERSION"
  git -C "$other" commit -qam v3
  git -C "$other" push -q origin "$branch"
  before="$(git -C "$CLONE" rev-parse HEAD)"
  up
  assert_contains "diverged checkout is left alone" "has diverged" \
    "$(cat "$STATE/update.log")"
  assert_eq "diverged checkout keeps its local commit" "$before" \
    "$(git -C "$CLONE" rev-parse HEAD)"

  # 5. the rate limit: a second run inside the interval does nothing.
  rm -f "$STATE/last-update-check"
  up
  n1="$(wc -l < "$STATE/update.log")"
  env -i HOME="$UP_SBX" PATH="/usr/bin:/bin" TERM=dumb \
    UPDATE_MARK="$STATE/mark" \
    ZIM_CLAUDE_STATE_DIR="$STATE" ZIM_CLAUDE_UPDATE_CONF="$STATE/update.conf" \
    ZIM_CLAUDE_UPDATE_LOG="$STATE/update.log" \
    bash "$REPO/scripts/zim-claude-update.sh"
  n2="$(wc -l < "$STATE/update.log")"
  assert_eq "second run inside the interval logs nothing" "$n1" "$n2"

  # 6. opt-out and unconfigured installs are silent no-ops.
  : > "$STATE/update.log"
  printf 'ZIM_CLAUDE_AUTO_UPDATE=0\n' > "$STATE/update.conf"
  up
  assert_eq "auto-update=0 is a no-op" "0" "$(wc -l < "$STATE/update.log")"
  rm -f "$STATE/update.conf"
  up
  assert_contains "missing config is reported, not crashed on" "not configured" \
    "$(cat "$STATE/update.log")"

  rm -rf "$UP_SBX"
fi

# The wrapper must not run the updater when told not to, and must not fail when
# the updater is absent.
section "auto-update wiring"

if grep -q 'ZIM_CLAUDE_NO_UPDATE' "$REPO/scripts/zim-claude"; then
  pass "wrapper honours ZIM_CLAUDE_NO_UPDATE"
else fail "wrapper ignores ZIM_CLAUDE_NO_UPDATE"; fi
if grep -q 'zim-claude-update.sh' "$REPO/install.sh"; then
  pass "installer ships the updater"
else fail "installer does not ship the updater"; fi
if grep -q 'write_update_conf' "$REPO/install.sh"; then
  pass "installer records the checkout"
else fail "installer does not record the checkout"; fi
if grep -q 'zim-claude-update.ps1' "$REPO/windows/zim-claude.ps1"; then
  pass "windows wrapper references the updater"
else fail "windows wrapper does not reference the updater"; fi

# ---------------------------------------------------------------- summary ---

printf '\n%s== summary%s\n' "$c_b" "$c_0"
printf '  %spassed: %d%s\n' "$c_g" "$PASS" "$c_0"
(( FAIL )) && printf '  %sfailed: %d%s\n' "$c_r" "$FAIL" "$c_0"
(( SKIP )) && printf '  %sskipped: %d%s\n' "$c_y" "$SKIP" "$c_0"
printf '\n'

(( FAIL )) && exit 1
exit 0
