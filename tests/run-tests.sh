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
  else fail "$1" "expected NOT to contain: $(printf '%q' "$2")"; fi
}

# ---------------------------------------------------------------- static ----

section "static checks"

for f in "$REPO/install.sh" "$REPO/scripts/zim-claude" "$REPO/scripts/zim-claude-update.sh" "$STUB"; do
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

# No hardcoded home directory anywhere — the package must work for any user.
if hits="$(grep -rn '/home/zim' "$REPO" --exclude-dir=.git --exclude-dir=tests 2>/dev/null)"; then
  fail "no hardcoded /home/zim" "$hits"
else pass "no hardcoded /home/zim"; fi

# The previous provider must be gone from the shipped surface. Its API host is
# the thing that would silently keep working and hide a half-finished
# migration. tests/ is excluded: it uses the old strings on purpose to
# reproduce the old layout.
if hits="$(grep -rni 'logfare\.ai' "$REPO" --exclude-dir=.git --exclude-dir=tests 2>/dev/null)"; then
  fail "no Logfare endpoint remains" "$hits"
else pass "no Logfare endpoint remains"; fi

# No Logfare key either. The bare prefix `lfu_` is still allowed, because
# install.sh matches it to recognise and clean up a shell config from the old
# version — that is a fingerprint, not a credential. A token has characters
# after it.
if hits="$(grep -rnE 'lfu_[A-Za-z0-9]' "$REPO" --exclude-dir=.git --exclude-dir=tests 2>/dev/null)"; then
  fail "no Logfare token remains" "$hits"
else pass "no Logfare token remains"; fi

if hits="$(grep -rni 'token.\?juice' "$REPO" --exclude-dir=.git --exclude-dir=tests 2>/dev/null)"; then
  fail "no Token Juice references remain" "$hits"
else pass "no Token Juice references remain"; fi

# TokenHarbor is the one upstream now, in the wrapper and the installer.
if grep -qF 'https://tokenharbor.ai' "$REPO/scripts/zim-claude"; then
  pass "wrapper defaults to the TokenHarbor API"
else fail "wrapper does not point at TokenHarbor"; fi

# No proxy: the whole LiteLLM layer (config, manager, virtualenv) is gone.
for gone in scripts/start-litellm.sh config/litellm-config.yaml config/token \
            windows claude-desktop-integration screenshots; do
  if [[ -e "$REPO/$gone" ]]; then fail "$gone is gone"
  else pass "$gone is gone"; fi
done

if grep -qE 'pip install|python3 -m venv|litellm --config' "$REPO/install.sh"; then
  fail "installer no longer builds a proxy runtime" \
       "install.sh still installs or launches litellm"
else pass "installer no longer builds a proxy runtime"; fi

# The only credential that ever shipped here was config/token. Nothing may
# carry a secret now: keys are typed at run time and never written down.
if grep -rqE 'sk-[A-Za-z0-9]{16,}|thk_(live|test)_[A-Za-z0-9]{16,}' "$REPO" \
     --exclude-dir=.git --exclude-dir=tests 2>/dev/null; then
  fail "no credential is shipped in the repo" "a key-shaped literal was found"
else pass "no credential is shipped in the repo"; fi

# --------------------------------------------------------------- readme ----

section "readme"

README="$REPO/README.md"
if [[ -f "$README" ]]; then
  pass "README present"
  assert_contains "README names the new API host" "tokenharbor.ai" "$(cat "$README")"
  assert_contains "README explains the per-run key prompt" "API key" "$(cat "$README")"
  assert_contains "README documents the Desktop gateway" "Gateway" "$(cat "$README")"
  assert_contains "README documents the custom model step" "Custom models" "$(cat "$README")"
  assert_lacks "README has no Windows section" "## Windows" "$(cat "$README")"
  # The migration section has to name what it is migrating *from*; what it must
  # not do is tell anyone to install a proxy runtime.
  assert_contains "README documents the migration" "Migrating from the LiteLLM version" "$(cat "$README")"
  assert_lacks "README does not ask anyone to install litellm" "pip install" "$(cat "$README")"
  # The media server is part of the package now, so the README has to say so.
  assert_contains "README documents the media server" "## Media" "$(cat "$README")"
  assert_contains "README names the media tools" "media_describe" "$(cat "$README")"
  assert_contains "README explains where media results land" "media/out" "$(cat "$README")"
else
  fail "README present"
fi

# ------------------------------------------------------------ media server ----

section "media MCP server"

MEDIA_SRC="$REPO/media/mcp-server.mjs"
if [[ -f "$MEDIA_SRC" ]]; then
  pass "media server present"
  # The server has to run on a bare Node: no npm install, no dependencies.
  # Every module specifier has to be a Node built-in.
  specs="$(grep -oE "(from|require\()[[:space:]]*['\"][^'\"]+['\"]" "$MEDIA_SRC" \
           | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" | sort -u || true)"
  if [[ -z "$specs" ]]; then
    fail "media server imports only Node built-ins" "no module specifiers found"
  elif grep -qv '^node:' <<<"$specs"; then
    fail "media server imports only Node built-ins" \
         "$(grep -v '^node:' <<<"$specs" | tr '\n' ' ')"
  else
    pass "media server imports only Node built-ins"
  fi

  if command -v node >/dev/null 2>&1; then
    if node --check "$MEDIA_SRC" >/dev/null 2>&1; then
      pass "media server parses under node"
    else fail "media server parses under node" "$(node --check "$MEDIA_SRC" 2>&1 | head -3)"; fi
  else
    skip "node not installed — media server not parsed"
  fi
else
  fail "media server present"
fi

# The media server talks to providers with keys the user supplies; no key may
# be baked into the source.
if hits="$(grep -rnE 'sk-[A-Za-z0-9]{16,}|thk_(live|test)_[A-Za-z0-9]{16,}' \
             "$REPO/media" 2>/dev/null)"; then
  fail "media server ships no credential" "$hits"
else pass "media server ships no credential"; fi

# -------------------------------------------------------------- sandbox ----

SBX="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-XXXXXX")"
trap 'rm -rf "$SBX"' EXIT

# The wrapper calls curl to validate the key and fetch the catalog. A stub
# answers from ZC_MODELS / ZC_STATUS so no test needs the network.
STUB_BIN="$SBX/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'EOF'
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
chmod +x "$STUB_BIN/curl"

sbx_install() {
  env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
    bash "$REPO/install.sh" "$@" </dev/null
}

section "install into sandbox \$HOME"

sbx_install >/dev/null 2>&1
# Exit 1 is expected: the sandbox PATH omits claude, so the installer reports a
# missing prerequisite. Files still land.
assert_eq "installer reports missing prereqs as exit 1" "1" "$?"
[[ -x "$SBX/.local/bin/zim-claude" ]] && pass "wrapper installed" || fail "wrapper installed"
[[ -x "$SBX/.local/bin/zim-claude-update.sh" ]] && pass "updater installed" || fail "updater installed"
[[ -x "$SBX/.local/share/zim-claude/media/mcp-server.mjs" ]] \
  && pass "media MCP server installed" || fail "media MCP server installed"
[[ -f "$SBX/.local/share/zim-claude/media/README.md" ]] \
  && pass "media README installed" || fail "media README installed"
[[ -e "$SBX/.local/share/zim-claude/venv" ]] \
  && fail "no proxy virtualenv is built" "installer created a venv" \
  || pass "no proxy virtualenv is built"
[[ -e "$SBX/litellm-config.yaml" ]] \
  && fail "no proxy config is installed" "litellm-config.yaml appeared" \
  || pass "no proxy config is installed"
[[ -e "$SBX/claude-source" ]] \
  && fail "no credential profile is written" "installer created claude-source/" \
  || pass "no credential profile is written"

assert_eq "wrapper mode 755" "755" "$(stat -c%a "$SBX/.local/bin/zim-claude" 2>/dev/null)"
assert_eq "state dir mode 700" "700" "$(stat -c%a "$SBX/.local/share/zim-claude" 2>/dev/null)"
assert_contains "PATH persisted to environment.d" "$SBX/.local/bin" \
  "$(cat "$SBX/.config/environment.d/zim-claude.conf" 2>/dev/null)"
assert_contains "bashrc marker block added" "# >>> zim-claude >>>" \
  "$(cat "$SBX/.bashrc" 2>/dev/null)"

section "idempotency"

out="$(sbx_install 2>&1)"
assert_contains "second run reports unchanged" "unchanged: $SBX/.local/bin/zim-claude" "$out"
n="$(sbx_install --dry-run 2>&1 | grep -c 'would: install')"
assert_eq "dry-run after install performs 0 installs" "0" "$n"
n="$(grep -c 'zim-claude' "$SBX/.bashrc")"
assert_eq "bashrc marker not duplicated" "3" "$n"

# record_state appends a row per install, so a file installed more than once
# has duplicate rows. The state file must still describe the file correctly.
sbx_install --force >/dev/null 2>&1
out="$(sbx_install 2>&1)"
if [[ "$out" == *"you have modified this file"* ]]; then
  fail "repeated installs keep recognising their own files" \
       "the state file's duplicate rows broke the hash comparison"
else
  pass "repeated installs keep recognising their own files"
fi
assert_eq "state file lists only current files" "4" \
  "$(wc -l < "$SBX/.local/share/zim-claude/installed.tsv")"

# ----------------------------------------------------- legacy migration ----

section "migrating a LiteLLM-era install"

LEG="$(mktemp -d "${TMPDIR:-/tmp}/zim-test-legacy-XXXXXX")"
mkdir -p "$LEG/bin" "$LEG/.local/bin" "$LEG/.local/share/zim-claude/venv/bin" "$LEG/claude-source"
ln -sf "$STUB" "$LEG/bin/claude"
printf '#!/bin/bash\n' > "$LEG/.local/bin/start-litellm.sh"; chmod 755 "$LEG/.local/bin/start-litellm.sh"
printf 'model_list: []\n' > "$LEG/litellm-config.yaml"
printf 'litellm[proxy]>=1.100.1 uvloop>=0.22.1\n' > "$LEG/.local/share/zim-claude/venv/.litellm-req"
printf '#!/bin/sh\n' > "$LEG/.local/share/zim-claude/venv/bin/litellm"
printf 'export ANTHROPIC_AUTH_TOKEN="lfu_OLDKEY"\n' > "$LEG/claude-source/deepseek-claude"
{
  for f in .local/bin/start-litellm.sh litellm-config.yaml; do
    printf '%s\t%s\t%s\n' "$LEG/$f" "$(sha256sum "$LEG/$f" | cut -d' ' -f1)" 755
  done
} > "$LEG/.local/share/zim-claude/installed.tsv"
cat > "$LEG/.bashrc" <<'EOF'
# user's own file
export EDITOR=vim
export ANTHROPIC_BASE_URL="http://localhost:4001"
export ANTHROPIC_AUTH_TOKEN="lfu_OLDKEY"
export ANTHROPIC_MODEL="deepseek-v4.1-flash"
export ANTHROPIC_API_KEY=""
alias ll='ls -l'
EOF
cp "$LEG/.bashrc" "$LEG/rc-orig"

leg_install() {
  env -i HOME="$LEG" PATH="$LEG/bin:/usr/bin:/bin" TERM=dumb \
    bash "$REPO/install.sh" "$@" </dev/null
}

out="$(leg_install 2>&1)"
assert_contains "the old proxy manager is removed" "removing a file from the previous version" "$out"
[[ -e "$LEG/.local/bin/start-litellm.sh" ]] \
  && fail "start-litellm.sh removed" "still present" || pass "start-litellm.sh removed"
[[ -e "$LEG/litellm-config.yaml" ]] \
  && fail "litellm-config.yaml removed" "still present" || pass "litellm-config.yaml removed"
[[ -e "$LEG/.local/share/zim-claude/venv" ]] \
  && fail "old virtualenv removed" "still present" || pass "old virtualenv removed"
[[ -e "$LEG/claude-source/deepseek-claude" ]] \
  && pass "the old credential file is kept, not deleted" \
  || fail "the old credential file is kept, not deleted" "installer deleted a credential"
assert_contains "the dead credential is reported" "no longer read by anything" "$out"

# The four exports aimed at a proxy that no longer exists are dead weight: they
# would make plain `claude` hang. They go; everything else in the file stays.
assert_lacks "the dead ANTHROPIC_* exports are gone" "ANTHROPIC_BASE_URL" "$(cat "$LEG/.bashrc")"
assert_lacks "the old token is gone from the shell config" "lfu_OLDKEY" "$(cat "$LEG/.bashrc")"
assert_contains "unrelated exports survive" "export EDITOR=vim" "$(cat "$LEG/.bashrc")"
assert_contains "aliases survive" "alias ll='ls -l'" "$(cat "$LEG/.bashrc")"
assert_contains "the PATH block is still added" "# >>> zim-claude >>>" "$(cat "$LEG/.bashrc")"

b="$(find "$LEG/.local/share/zim-claude/backups" -name '.bashrc' 2>/dev/null | head -1)"
if [[ -n "$b" ]] && cmp -s "$b" "$LEG/rc-orig"; then
  pass "the backup holds the pre-install shell config"
else
  fail "the backup holds the pre-install shell config" \
       "a later edit overwrote the first backup of the run"
fi

# A shell aimed at some other provider is the user's own: never rewritten.
printf 'export ANTHROPIC_BASE_URL="https://api.example-provider.test/v1"\n' > "$LEG/.bashrc"
printf 'export ANTHROPIC_AUTH_TOKEN="their-key"\n' >> "$LEG/.bashrc"
leg_install >/dev/null 2>&1
assert_contains "a foreign provider's shell config is untouched" "their-key" \
  "$(cat "$LEG/.bashrc")"

# --no-rc must not touch the shell config at all, cleanup included.
printf 'export ANTHROPIC_BASE_URL="http://localhost:4001"\n' > "$LEG/.bashrc"
printf 'export ANTHROPIC_AUTH_TOKEN="lfu_OLDKEY"\n' >> "$LEG/.bashrc"
out="$(leg_install --no-rc 2>&1)"
assert_contains "--no-rc keeps the stale exports" "lfu_OLDKEY" "$(cat "$LEG/.bashrc")"
assert_contains "--no-rc says why" "left alone (--no-rc)" "$out"
rm -rf "$LEG"

# --------------------------------------------------------------- wrapper ---

section "wrapper: key handling"

ZC="$SBX/.local/bin/zim-claude"

# Prompting needs a terminal, so those cases run under `script` with a pty.
if ! command -v script >/dev/null 2>&1; then
  skip "script(1) not available — cannot drive the interactive prompts"
else
  # zc_pty <stdin> <shell-snippet> [models-json]
  zc_pty() {
    printf '%s' "$1" | env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
      ZC_MODELS="${3:-}" ZC_STATUS="200" \
      script -qec "$2" /dev/null 2>&1
  }

  # No key in the environment: the wrapper must ask, and the typed key must be
  # the one it uses.
  out="$(zc_pty $'thk_live_TYPED\n\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "the wrapper asks for a key" "paste it here" "$out"
  assert_contains "the typed key is accepted" "TOKEN_SET=yes" "$out"

  # Enter with no key typed is not a key.
  out="$(zc_pty $'\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "an empty key is refused" "a TokenHarbor API key is required" "$out"
fi

# A key from the environment skips the prompt entirely.
out="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="thk_live_ENVKEY" \
  ZIM_CLAUDE_MODEL="deepseek-v4.1-flash:free" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_STATE_DIR="$SBX/state" "$ZC" --version 2>&1)"
assert_lacks "an environment key skips the prompt" "paste it here" "$out"
assert_contains "an environment key is used" "TOKEN_SET=yes" "$out"

# A rejected environment key is fatal — retyping it cannot help.
err="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb ZC_STATUS=401 \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="thk_live_BAD" \
  ZIM_CLAUDE_MODEL="deepseek-v4.1-flash:free" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_STATE_DIR="$SBX/state" "$ZC" --version 2>&1 >/dev/null)"
assert_eq "a rejected environment key exits 2" "2" "$?"
assert_contains "a rejected environment key says where to rotate" \
  "Rotate it at https://tokenharbor.ai/dashboard/api-keys" "$err"

# No terminal and no key: fail closed rather than running against whatever
# ANTHROPIC_* the shell happens to export.
err="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_NO_UPDATE=1 ZIM_CLAUDE_STATE_DIR="$SBX/state" \
  setsid "$ZC" --version 2>&1 >/dev/null </dev/null)"
assert_eq "no terminal and no key exits 2" "2" "$?"
assert_contains "no terminal explains the fix" "export ZIM_CLAUDE_API_KEY" "$err"

section "wrapper: the free-model picker"

if command -v script >/dev/null 2>&1; then
  # The catalog has five ids, three of them free. Only the free ones are offered.
  out="$(zc_pty $'thk_live_TYPED\n1\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "free models are listed" "deepseek-v4.1-flash:free" "$out"
  assert_contains "a second free model is listed" "mimo-v2.6-flash:free" "$out"
  assert_contains "th-rudder counts as free" "th-rudder" "$out"
  assert_lacks "a paid model is not offered" "claude-opus-5.5" "$out"
  assert_lacks "another paid model is not offered" "gpt-6-astra" "$out"

  # Selecting the second entry uses the second free model.
  out="$(zc_pty $'thk_live_TYPED\n2\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "the second entry is selected" "MODEL=mimo-v2.6-flash:free" "$out"

  # A remembered choice becomes the default, so Enter is stable. The first line
  # is the key prompt, the empty second line accepts the default.
  out="$(zc_pty $'thk_live_TYPED\n\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "the last pick is remembered as the default" "select 1-3 [2]" "$out"

  # Nonsense is re-asked, not accepted.
  out="$(zc_pty $'thk_live_TYPED\n9\n1\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state ZIM_CLAUDE_NO_UPDATE=1 $ZC --version")"
  assert_contains "an out-of-range choice is rejected" "not a choice: 9" "$out"
  assert_contains "a valid choice still works after that" "MODEL=deepseek-v4.1-flash:free" "$out"

  # A catalog with no :free ids falls back to the whole list instead of
  # refusing to start.
  out="$(zc_pty $'thk_live_TYPED\n\n' \
        "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state ZIM_CLAUDE_NO_UPDATE=1 $ZC --version" \
        '{"data":[{"id":"claude-opus-5.5"},{"id":"gpt-6-astra"}]}')"
  assert_contains "a catalog with no free route says so" "no free model is advertised" "$out"
  assert_contains "a catalog with no free route still offers models" "claude-opus-5.5" "$out"
fi

# A pinned model skips the picker entirely.
out="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="thk_live_ENVKEY" \
  ZIM_CLAUDE_MODEL="mimo-v2.6-flash:free" ZIM_CLAUDE_NO_UPDATE=1 \
  ZIM_CLAUDE_STATE_DIR="$SBX/state" "$ZC" --version 2>&1)"
assert_lacks "a pinned model skips the picker" "free models on" "$out"
assert_contains "a pinned model is used" "MODEL=mimo-v2.6-flash:free" "$out"

section "wrapper: failure modes"

err="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb ZC_STATUS=000 \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="thk_live_ENVKEY" \
  ZIM_CLAUDE_MODEL="x" ZIM_CLAUDE_NO_UPDATE=1 ZIM_CLAUDE_STATE_DIR="$SBX/state" \
  "$ZC" --version 2>&1 >/dev/null)"
assert_eq "an unreachable API exits 2" "2" "$?"
assert_contains "an unreachable API names the host" "could not reach https://tokenharbor.ai" "$err"

err="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb ZC_MODELS='{"data":[]}' \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="thk_live_ENVKEY" \
  ZIM_CLAUDE_NO_UPDATE=1 ZIM_CLAUDE_STATE_DIR="$SBX/state" \
  "$ZC" --version 2>&1 >/dev/null)"
assert_eq "an empty catalog exits 2" "2" "$?"
assert_contains "an empty catalog says so" "returned no model ids" "$err"

err="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb ZC_STATUS=500 \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="thk_live_ENVKEY" \
  ZIM_CLAUDE_NO_UPDATE=1 ZIM_CLAUDE_STATE_DIR="$SBX/state" \
  "$ZC" --version 2>&1 >/dev/null)"
assert_eq "an unexpected status exits 2" "2" "$?"
assert_contains "an unexpected status reports the code" "HTTP 500" "$err"

env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN=/nonexistent/claude ZIM_CLAUDE_API_KEY="k" \
  ZIM_CLAUDE_MODEL="m" ZIM_CLAUDE_NO_UPDATE=1 "$ZC" --version >/dev/null 2>&1
assert_eq "missing claude binary exits 2" "2" "$?"

# A non-zero exit from claude must pass through untouched, not become 2.
cat > "$SBX/stub-fail" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$SBX/stub-fail"
env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$SBX/stub-fail" ZIM_CLAUDE_API_KEY="k" ZIM_CLAUDE_MODEL="m" \
  ZIM_CLAUDE_NO_UPDATE=1 "$ZC" >/dev/null 2>&1
assert_eq "claude's exit code passes through" "42" "$?"

section "wrapper: argument pass-through"

run_stub() { env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="k" ZIM_CLAUDE_MODEL="m" \
  ZIM_CLAUDE_NO_UPDATE=1 "$ZC" "$@" 2>/dev/null; }

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

section "wrapper: environment"

out="$(run_stub --version)"
assert_contains "the API base URL is exported" "BASE_URL=https://tokenharbor.ai" "$out"
assert_contains "the chosen model is exported" "MODEL=m" "$out"
assert_contains "the auth token is exported" "TOKEN_SET=yes" "$out"
assert_contains "ANTHROPIC_API_KEY is empty" "APIKEY=<>" "$out"

# Inherited ANTHROPIC_* must be replaced for this process and reported.
out="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="k" ZIM_CLAUDE_MODEL="m" \
  ZIM_CLAUDE_NO_UPDATE=1 ANTHROPIC_BASE_URL="https://other.example/" "$ZC" --version 2>/dev/null)"
assert_contains "an inherited base URL is overridden" "BASE_URL=https://tokenharbor.ai" "$out"

err="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="k" ZIM_CLAUDE_MODEL="m" \
  ZIM_CLAUDE_NO_UPDATE=1 ANTHROPIC_BASE_URL="https://other.example/" "$ZC" --version 2>&1 >/dev/null)"
assert_contains "the override is reported on stderr" "overriding inherited ANTHROPIC_BASE_URL" "$err"

out="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="k" ZIM_CLAUDE_MODEL="m" \
  ZIM_CLAUDE_NO_UPDATE=1 ANTHROPIC_API_KEY="sk-a-real-key" "$ZC" --version 2>/dev/null)"
assert_contains "an inherited API key is cleared" "APIKEY=<>" "$out"

# set -a must not leak: only names the wrapper assigns are touched.
out="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="k" ZIM_CLAUDE_MODEL="m" \
  ZIM_CLAUDE_NO_UPDATE=1 ZIM_TEST_UNRELATED="untouched" "$ZC" --version 2>/dev/null)"
assert_contains "an unrelated env var survives" "UNRELATED=untouched" "$out"

section "wrapper: stdout hygiene and secrecy"

out="$(env -i HOME="$SBX" PATH="$STUB_BIN:/usr/bin:/bin" TERM=dumb \
  ZIM_CLAUDE_BIN="$STUB" ZIM_CLAUDE_API_KEY="k" ZIM_CLAUDE_MODEL="m" \
  ZIM_CLAUDE_NO_UPDATE=1 ANTHROPIC_BASE_URL="https://other.example/" "$ZC" --version 2>/dev/null)"
assert_contains "the stub's output reaches stdout" "ARGC=1" "$out"
assert_lacks "warnings stay off stdout" "overriding" "$out"

# The key is a runtime secret: it must never be written anywhere.
if command -v script >/dev/null 2>&1; then
  zc_pty $'thk_live_NEVERONDISK\n\n' \
    "ZIM_CLAUDE_BIN=$STUB ZIM_CLAUDE_STATE_DIR=$SBX/state ZIM_CLAUDE_NO_UPDATE=1 $ZC --version" \
    >/dev/null 2>&1
  if hits="$(grep -rl 'thk_live_NEVERONDISK' "$SBX" 2>/dev/null)"; then
    fail "the typed key is never written to disk" "$hits"
  else
    pass "the typed key is never written to disk"
  fi
fi

# -------------------------------------------------------------- uninstall --

section "uninstall"

echo "# hand edit" >> "$SBX/.local/bin/zim-claude"
sbx_install --uninstall >/dev/null 2>&1
[[ -e "$SBX/.local/bin/zim-claude" ]] && pass "a modified file is left in place" \
  || fail "a modified file is left in place"
[[ -e "$SBX/.local/bin/zim-claude-update.sh" ]] \
  && fail "an unmodified file is removed" "updater still present" \
  || pass "an unmodified file is removed"
n="$(grep -c 'zim-claude' "$SBX/.bashrc" 2>/dev/null || true)"
assert_eq "the bashrc marker is removed" "0" "$n"
[[ -e "$SBX/.config/environment.d/zim-claude.conf" ]] \
  && fail "the environment.d entry is removed" "still present" \
  || pass "the environment.d entry is removed"

# ---------------------------------------------------------- auto-update ----

section "auto-update"

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
  # Minimal checkout: the updater re-runs install.sh, so it must be present and
  # must succeed without touching the network or the real $HOME.
  cat > "$CLONE/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'installed %s (args: %s)\n' "$(cat "$(dirname "$0")/VERSION")" "$*" >> "${UPDATE_MARK:?}"
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

  up
  assert_eq "updater exits 0 when up to date" "0" "$?"
  assert_contains "updater reports up to date" "already up to date" \
    "$(cat "$STATE/update.log" 2>/dev/null)"

  git -C "$CLONE" pull -q origin "$branch"
  printf 'v2\n' > "$CLONE/VERSION"
  git -C "$CLONE" commit -qam v2
  git -C "$CLONE" push -q origin "$branch"
  git -C "$CLONE" reset -q --hard HEAD~1
  up
  assert_contains "updater fast-forwards" "updated " "$(cat "$STATE/update.log")"
  assert_eq "the fast-forward reaches the new commit" "v2" "$(cat "$CLONE/VERSION")"
  assert_contains "the installer ran after the update" "installed v2" \
    "$(cat "$STATE/mark" 2>/dev/null)"
  # The updater must not pass flags the installer no longer has.
  assert_contains "the updater calls the installer with --no-rc" "--no-rc" \
    "$(cat "$STATE/mark" 2>/dev/null)"
  assert_lacks "the updater does not pass a removed --no-venv" "--no-venv" \
    "$(cat "$STATE/mark" 2>/dev/null)"

  printf 'local edit\n' >> "$CLONE/VERSION"
  before="$(git -C "$CLONE" rev-parse HEAD)"
  up
  assert_contains "a dirty checkout is not updated" "has local changes" \
    "$(cat "$STATE/update.log")"
  assert_eq "a dirty checkout keeps its HEAD" "$before" "$(git -C "$CLONE" rev-parse HEAD)"
  git -C "$CLONE" checkout -q -- VERSION

  printf 'local\n' > "$CLONE/LOCAL"
  git -C "$CLONE" add -A
  git -C "$CLONE" commit -qm local-only
  other="$UP_SBX/other"
  git clone -q "$ORIGIN" "$other" 2>/dev/null
  git -C "$other" config user.name "Test"
  git -C "$other" config user.email "test@example.invalid"
  printf 'v3\n' > "$other/VERSION"
  git -C "$other" commit -qam v3
  git -C "$other" push -q origin "$branch"
  before="$(git -C "$CLONE" rev-parse HEAD)"
  up
  assert_contains "a diverged checkout is left alone" "has diverged" \
    "$(cat "$STATE/update.log")"
  assert_eq "a diverged checkout keeps its local commit" "$before" \
    "$(git -C "$CLONE" rev-parse HEAD)"

  rm -f "$STATE/last-update-check"
  up
  n1="$(wc -l < "$STATE/update.log")"
  env -i HOME="$UP_SBX" PATH="/usr/bin:/bin" TERM=dumb \
    UPDATE_MARK="$STATE/mark" \
    ZIM_CLAUDE_STATE_DIR="$STATE" ZIM_CLAUDE_UPDATE_CONF="$STATE/update.conf" \
    ZIM_CLAUDE_UPDATE_LOG="$STATE/update.log" \
    bash "$REPO/scripts/zim-claude-update.sh"
  n2="$(wc -l < "$STATE/update.log")"
  assert_eq "a second run inside the interval logs nothing" "$n1" "$n2"

  : > "$STATE/update.log"
  printf 'ZIM_CLAUDE_AUTO_UPDATE=0\n' > "$STATE/update.conf"
  up
  assert_eq "auto-update=0 is a no-op" "0" "$(wc -l < "$STATE/update.log")"
  rm -f "$STATE/update.conf"
  up
  assert_contains "a missing config is reported, not crashed on" "not configured" \
    "$(cat "$STATE/update.log")"

  rm -rf "$UP_SBX"
fi

section "auto-update wiring"

if grep -q 'ZIM_CLAUDE_NO_UPDATE' "$REPO/scripts/zim-claude"; then
  pass "the wrapper honours ZIM_CLAUDE_NO_UPDATE"
else fail "the wrapper ignores ZIM_CLAUDE_NO_UPDATE"; fi
if grep -q 'zim-claude-update.sh' "$REPO/install.sh"; then
  pass "the installer ships the updater"
else fail "the installer does not ship the updater"; fi
if grep -q 'write_update_conf' "$REPO/install.sh"; then
  pass "the installer records the checkout"
else fail "the installer does not record the checkout"; fi

# ---------------------------------------------------------------- summary ---

printf '\n%s== summary%s\n' "$c_b" "$c_0"
printf '  %spassed: %d%s\n' "$c_g" "$PASS" "$c_0"
(( FAIL )) && printf '  %sfailed: %d%s\n' "$c_r" "$FAIL" "$c_0"
(( SKIP )) && printf '  %sskipped: %d%s\n' "$c_y" "$SKIP" "$c_0"
printf '\n'

(( FAIL )) && exit 1
exit 0
