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

# The whole point of config/.token.b64: the token must not be greppable.
if hits="$(grep -rnE 'tj_[A-Za-z0-9]{10,}' "$REPO" --exclude-dir=.git 2>/dev/null)"; then
  fail "no plaintext token in repo" "$hits"
else pass "no plaintext token in repo"; fi

if [[ -f "$REPO/config/.token.b64" ]]; then
  if [[ -n "$(base64 -d < "$REPO/config/.token.b64" 2>/dev/null)" ]]; then
    pass "config/.token.b64 decodes to a non-empty token"
  else fail "config/.token.b64 does not decode"; fi
else fail "config/.token.b64 missing"; fi

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
want="$(base64 -d < "$REPO/config/.token.b64")"
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

# ---------------------------------------------------------------- summary ---

printf '\n%s== summary%s\n' "$c_b" "$c_0"
printf '  %spassed: %d%s\n' "$c_g" "$PASS" "$c_0"
(( FAIL )) && printf '  %sfailed: %d%s\n' "$c_r" "$FAIL" "$c_0"
(( SKIP )) && printf '  %sskipped: %d%s\n' "$c_y" "$SKIP" "$c_0"
printf '\n'

(( FAIL )) && exit 1
exit 0
