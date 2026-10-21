#!/usr/bin/env bash
# install.sh — install the zim-claude package for the invoking user.
#
#   ./install.sh                install into $HOME
#   ./install.sh --dry-run      print every action, change nothing
#   ./install.sh --uninstall    remove what this installer created
#   ./install.sh --force        overwrite files you have hand-edited (still backs up)
#   ./install.sh --no-rc        don't touch ~/.bashrc
#   ./install.sh --start        start the LiteLLM proxy when done
#   ./install.sh --no-venv      never build the proxy virtualenv
#   ./install.sh --port N       use port N instead of auto-detecting one
#   ./install.sh --help
#
# Everything is derived from $HOME, so this works for any user on any machine.

set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# --- what we install, and where ---------------------------------------------
# The model-name configuration and the credential live together in ONE
# directory outside this checkout: ~/tokenjuice/, the Token Juice route this
# package drives. start-litellm.sh ships verbatim and its built-in defaults
# point at exactly these locations, so the two must agree.
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

TOKENJUICE_DIR="${ZIM_CLAUDE_TOKENJUICE_DIR:-$HOME/tokenjuice}"
ENV_FILE="$TOKENJUICE_DIR/source"
CONFIG_FILE="$TOKENJUICE_DIR/litellm-config.yaml"

# The old layout, kept only so an upgrade can point at it.
LEGACY_ENV_FILE="$HOME/claude-source/deepseek-claude"
LEGACY_CONFIG_FILE="$HOME/litellm-config.yaml"

STATE_DIR="$HOME/.local/share/zim-claude"
STATE_FILE="$STATE_DIR/installed.tsv"
BACKUP_ROOT="$STATE_DIR/backups"
UPDATE_CONF="$STATE_DIR/update.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"

# The proxy gets its OWN virtualenv, built here rather than pip-installed into
# the system Python — no distro-flag override, nothing to activate by hand.
# scripts/start-litellm.sh ships verbatim and looks for exactly this path, so
# the two files must agree on it (and neither may hardcode $HOME).
PROXY_VENV="$STATE_DIR/venv"
PROXY_PY="$PROXY_VENV/bin/python"
PROXY_LITELLM="$PROXY_VENV/bin/litellm"
REQ_STAMP="$PROXY_VENV/.litellm-req"

ENVD_DIR="$HOME/.config/environment.d"
ENVD_CONF="$ENVD_DIR/zim-claude.conf"
MARKER_BEGIN="# >>> zim-claude >>>"
MARKER_END="# <<< zim-claude <<<"

# Where the CLI proxy lives by default. 4000 is the Token Juice / ZimZilla port;
# the probe below still moves away from it if something else owns it.
# 4002 is deliberately absent from the candidate list: that is the Claude
# Desktop gateway, and pointing the CLI at it would replace the desktop app's
# route. Overridable so a test (or a machine with an unusual range) can use
# different ports.
PROXY_PORT_DEFAULT="${ZIM_CLAUDE_DEFAULT_PORT:-4000}"
PORT_CANDIDATES="${ZIM_CLAUDE_PORT_CANDIDATES:-4000 4001 4003 4004 4005 4006 4007 4008 4009 4010}"

# The model name written into profiles. Must be a model_name in
# $CONFIG_FILE and a name Token Juice still serves: the upstream id carries a
# snapshot suffix Token Juice rotates, and a stale suffix fails as a 404 that
# looks like a broken proxy.
PROFILE_MODEL="${ZIM_CLAUDE_MODEL:-deepseek-v4.1-flash-1017}"

# Filled in by install_config_env; migrate_shell_rc writes the same port.
PROXY_PORT_CHOSEN=""
PROFILE_TOKEN_EFFECTIVE=""

# --- flags -------------------------------------------------------------------
DRY_RUN=0 UNINSTALL=0 FORCE=0 TOUCH_RC=1 DO_START=0 DO_VENV=1
PROXY_PORT=""

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --force)     FORCE=1 ;;
    --no-rc)     TOUCH_RC=0 ;;
    --start)     DO_START=1 ;;
    --no-venv)   DO_VENV=0 ;;
    --port)
      [[ $# -ge 2 ]] || { printf -- '--port needs a value\n\n' >&2; usage >&2; exit 2; }
      PROXY_PORT="$2"; shift ;;
    --port=*)    PROXY_PORT="${1#--port=}" ;;
    -h|--help)   usage; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$PROXY_PORT" && ! "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
  printf 'invalid --port: %s (expected a number)\n' "$PROXY_PORT" >&2
  exit 2
fi

# --- output ------------------------------------------------------------------
say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }

# Every mutation goes through run(), so --dry-run is honest.
run() {
  if (( DRY_RUN )); then printf '    would: %s\n' "$*"
  else "$@"; fi
}

# --- state tracking ----------------------------------------------------------
# path<TAB>sha256<TAB>mode — lets --uninstall tell "we installed this" from
# "the user edited it since".

record_state() {
  local path="$1" mode="$2" hash
  hash="$(sha256sum -- "$path" 2>/dev/null | cut -d' ' -f1 || true)"
  (( DRY_RUN )) && return 0
  run mkdir -p -- "$STATE_DIR"
  run chmod 700 -- "$STATE_DIR"
  printf '%s\t%s\t%s\n' "$path" "$hash" "$mode" >>"$STATE_FILE"
  run chmod 600 -- "$STATE_FILE"
}

recorded_hash() {
  [[ -f "$STATE_FILE" ]] || return 1
  # The LAST matching line, not every match. record_state appends on each
  # install, so a re-installed file has several rows; printing them all would
  # make `want` a multi-line string that can never equal a single hash, and
  # every later install would report the file as user-modified.
  awk -F'\t' -v p="$1" '$1==p {h=$2; found=1} END{if (!found) exit 1; print h}' "$STATE_FILE"
}

file_is_ours() {
  local path="$1" want got
  want="$(recorded_hash "$path")" || return 1
  got="$(sha256sum -- "$path" 2>/dev/null | cut -d' ' -f1 || true)"
  [[ "$want" == "$got" ]]
}

# --- backups -----------------------------------------------------------------

backup_if_exists() {
  local target="$1" rel dest
  [[ -e "$target" || -L "$target" ]] || return 0
  rel="${target#"$HOME"/}"
  dest="$BACKUP_ROOT/$STAMP/${rel//\//__}"
  say "backing up $target -> $dest"
  run mkdir -p -- "$(dirname -- "$dest")"
  run chmod 700 -- "$BACKUP_ROOT" "$BACKUP_ROOT/$STAMP"
  run cp -a -- "$target" "$dest"
}

# --- file installation -------------------------------------------------------

install_file() {   # install_file <src> <dest> <mode>
  local src="$1" dest="$2" mode="$3"

  if [[ -e "$dest" ]] && cmp -s -- "$src" "$dest"; then
    say "unchanged: $dest"
    run chmod "$mode" -- "$dest"
    return 0
  fi

  if [[ -e "$dest" ]] && (( ! FORCE )) && ! file_is_ours "$dest"; then
    warn "you have modified this file — leaving it alone: $dest"
    warn "  re-run with --force to overwrite (a backup is still taken)"
    return 0
  fi

  backup_if_exists "$dest"
  say "installing $dest"
  run install -D -m "$mode" -- "$src" "$dest"
  record_state "$dest" "$mode"
}

# --- choosing a proxy port ---------------------------------------------------
#
# The profile points claude at a local proxy, and the proxy is only useful if it
# accepts the profile's token. Two things make a fixed default wrong:
#
#   - another LiteLLM (ZimZilla's, a leftover install) already holds the port
#     and rejects the token, answering every request with "No connected db."
#   - that other proxy is fine, but it is on a different port.
#
# So the installer probes: it keeps a port that already accepts the token, keeps
# a free port (zim-claude will start its own proxy there), and otherwise moves
# to the first candidate that works. --port overrides the whole search.

# port_open <port> — something is listening. curl reports 000 when it cannot
# connect, so no HTTP status at all means "free".
port_open() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
      "http://127.0.0.1:$1/health/liveliness" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]]
}

# proxy_accepts_token <port> <token> — a LiteLLM proxy on this port was started
# with a master key matching the token. /v1/models is the cheapest endpoint that
# authenticates: a mismatched master key answers 400 ("No connected db."), an
# unauthenticated service answers 401.
proxy_accepts_token() {
  local port="$1" token="$2" code
  # A proxy started without a master key answers everything; one started with a
  # different key answers 401. Either way it is not ours to talk to.
  [[ -n "$token" ]] || return 1
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      -H "Authorization: Bearer $token" \
      "http://127.0.0.1:$port/v1/models" 2>/dev/null || true)"
  [[ "$code" == "200" ]]
}

# port_from_url <url> — the port a base URL points at, the default if it names
# none.
port_from_url() {
  local url="$1" port
  port="${url##*:}"
  port="${port%%/*}"
  if [[ "$port" =~ ^[0-9]+$ ]]; then printf '%s' "$port"; else printf '%s' "$PROXY_PORT_DEFAULT"; fi
}

# points_at_local_proxy <url> — the profile aims at a proxy on this machine.
# That is the only kind of profile this installer manages; one aimed at a
# provider directly is the user's own and is never rewritten.
points_at_local_proxy() {
  [[ "$1" == *localhost:* || "$1" == *127.0.0.1:* ]]
}

# choose_proxy_port <token> [<current-url>] — sets PROXY_PORT_CHOSEN.
choose_proxy_port() {
  local token="$1" current_url="${2:-}" current_port="" p

  if [[ -n "$PROXY_PORT" ]]; then
    PROXY_PORT_CHOSEN="$PROXY_PORT"
    say "proxy port: $PROXY_PORT_CHOSEN (--port)"
    return 0
  fi

  # 1. The port already recorded in the profile, if it is usable as-is.
  if [[ -n "$current_url" ]]; then
    current_port="$(port_from_url "$current_url")"
    if proxy_accepts_token "$current_port" "$token"; then
      PROXY_PORT_CHOSEN="$current_port"
      say "proxy port: $current_port (already accepting the profile's token)"
      return 0
    fi
    if ! port_open "$current_port"; then
      PROXY_PORT_CHOSEN="$current_port"
      say "proxy port: $current_port (free — zim-claude will start the proxy there)"
      return 0
    fi
    warn "port :$current_port is taken by something that rejects the profile's token"
  fi

  # 2. A proxy that already accepts the token, wherever it is.
  for p in $PORT_CANDIDATES; do
    if proxy_accepts_token "$p" "$token"; then
      PROXY_PORT_CHOSEN="$p"
      say "proxy port: $p (a running proxy already accepts the token)"
      return 0
    fi
  done

  # 3. A free port, so we can start our own proxy.
  for p in $PORT_CANDIDATES; do
    if ! port_open "$p"; then
      PROXY_PORT_CHOSEN="$p"
      say "proxy port: $p (free)"
      return 0
    fi
  done

  PROXY_PORT_CHOSEN="${PORT_CANDIDATES%% *}"
  warn "every candidate port is busy and none accepts the token."
  warn "  falling back to :$PROXY_PORT_CHOSEN — pass --port N to choose another."
}

# --- the model configuration -------------------------------------------------
#
# The model names live in ~/tokenjuice/litellm-config.yaml, next to the
# credential, and that directory is shared with whatever else on this box drives
# the same Token Juice route. So an existing config belongs to whoever put it
# there: it is used as-is and never rewritten, even with --force. Only a missing
# one is created, from the copy in this repo.
install_config_yaml() {
  run mkdir -p -- "$TOKENJUICE_DIR"
  run chmod 700 -- "$TOKENJUICE_DIR"

  if [[ -e "$CONFIG_FILE" ]]; then
    say "using the model configuration already in place: $CONFIG_FILE"
    if ! grep -q 'model_name:' "$CONFIG_FILE" 2>/dev/null; then
      warn "$CONFIG_FILE has no model_list — the proxy will reject every request."
    fi
    return 0
  fi

  say "installing $CONFIG_FILE (first install — yours from now on)"
  run install -D -m 644 -- "$SRC_DIR/config/litellm-config.yaml" "$CONFIG_FILE"
}

# --- the env profile ---------------------------------------------------------

# The env file is special: it holds a live credential, so it is never
# overwritten — not even with --force. Losing it would mean re-issuing a token.
# No credential ships in this checkout: the key is either already in the
# profile, in $ZIM_CLAUDE_TOKEN for a scripted install, or typed at a prompt.
#
# One thing is repaired, with a backup: a profile aimed at the local proxy whose
# base URL names a port that rejects its own token. That is a real machine —
# another proxy holds the port and answers "No connected db." — and the token is
# fine, the port is not, so only the port is moved.
#
# A profile aimed somewhere other than the local proxy is the user's own and is
# left alone.

# ask_token — read a Token Juice key from the terminal with echo off, into
# PROFILE_TOKEN_EFFECTIVE. Fails when there is no terminal to ask on (CI, a
# piped install); that is exactly the case ZIM_CLAUDE_TOKEN exists for.
ask_token() {
  local typed=""
  { exec 3</dev/tty; } 2>/dev/null || return 1
  printf '\n' >&2
  say "Token Juice API key — create one at https://tokenjuice.ai"
  printf '  paste it here (input is hidden): ' >&2
  IFS= read -r -s typed <&3 || typed=""
  exec 3<&-
  printf '\n' >&2
  typed="$(printf '%s' "$typed" | tr -d ' \t\r\n')"
  [[ -n "$typed" ]] || return 1
  PROFILE_TOKEN_EFFECTIVE="$typed"
  return 0
}

install_config_env() {
  run mkdir -p -- "$TOKENJUICE_DIR"
  run chmod 700 -- "$TOKENJUICE_DIR"

  local token="" src=""
  # Scripted installs can pass the key in. Trims surrounding whitespace,
  # including the CR a copy-paste through a browser adds — a trailing CR inside
  # the export breaks authentication with a 401 that looks like a bad key.
  if [[ -n "${ZIM_CLAUDE_TOKEN:-}" ]]; then
    token="$(printf '%s' "$ZIM_CLAUDE_TOKEN" | tr -d ' \t\r\n')"
    src="ZIM_CLAUDE_TOKEN"
  fi

  PROFILE_TOKEN_EFFECTIVE="$token"

  if [[ -e "$ENV_FILE" ]]; then
    local current="" current_url=""
    current="$(sed -n 's/^export ANTHROPIC_AUTH_TOKEN="\(.*\)"$/\1/p' "$ENV_FILE" 2>/dev/null | head -1)"
    current_url="$(sed -n 's/^export ANTHROPIC_BASE_URL="\(.*\)"$/\1/p' "$ENV_FILE" 2>/dev/null | head -1)"

    if [[ -n "$current" ]]; then
      # The profile already holds a credential. Keep it — never overwriting
      # this file is the point — and make sure the port it names works.
      case "$current" in
        tj_*) : ;;
        *) warn "$ENV_FILE holds a key that does not look like a Token Juice key (tj_…)."
           warn "  Keeping it: if it belongs to another provider, Token Juice will reject it." ;;
      esac
      PROFILE_TOKEN_EFFECTIVE="$current"
      choose_proxy_port "$current" "$current_url"
      if [[ -z "$current_url" ]] || \
         [[ "$PROXY_PORT_CHOSEN" == "$(port_from_url "$current_url")" ]]; then
        say "keeping existing env file: $ENV_FILE (never overwritten)"
        run chmod 600 -- "$ENV_FILE"
        return 0
      fi
      backup_if_exists "$ENV_FILE"
      say "moving the env profile to port :$PROXY_PORT_CHOSEN (it rejected its token on :$(port_from_url "$current_url"))"
      if (( DRY_RUN )); then
        printf '    would rewrite ANTHROPIC_BASE_URL to http://localhost:%s\n' "$PROXY_PORT_CHOSEN"
        return 0
      fi
      : >"$ENV_FILE"
      token="$current"

    else
      # The file exists but carries no ANTHROPIC_AUTH_TOKEN (comments, or a
      # profile someone emptied). Fall through and write a complete one.
      choose_proxy_port "$token" "$current_url"
    fi
  else
    choose_proxy_port "$token"
  fi

  if [[ -z "$token" ]]; then
    if (( DRY_RUN )); then
      printf '    would ask for a Token Juice key (none ships in the repo)\n'
      return 0
    fi
    # Nothing to install from and no credential in the profile: ask for one.
    # Hidden input, never echoed, never written anywhere but the profile.
    if ask_token; then
      token="$PROFILE_TOKEN_EFFECTIVE"
      src="the key you typed"
    else
      err "no Token Juice key available."
      err "  either export ZIM_CLAUDE_TOKEN=tj_… and re-run, or create"
      err "  $ENV_FILE by hand:"
      err "    export ANTHROPIC_AUTH_TOKEN=\"tj_…\""
      return 1
    fi
  fi

  case "$token" in
    *[!A-Za-z0-9_.:-]*)
      err "token in $src contains unexpected characters — refusing to install it"
      return 1 ;;
  esac

  say "writing env file: $ENV_FILE"
  if (( DRY_RUN )); then
    printf '    would write 4 ANTHROPIC_* exports (token redacted)\n'
    return 0
  fi

  install -D -m 600 /dev/null "$ENV_FILE"
  cat >"$ENV_FILE" <<EOF
export ANTHROPIC_BASE_URL="http://localhost:$PROXY_PORT_CHOSEN"
export ANTHROPIC_AUTH_TOKEN="$token"
export ANTHROPIC_MODEL="$PROFILE_MODEL"
export ANTHROPIC_API_KEY=""
EOF
  chmod 600 -- "$ENV_FILE"
  ok "wrote $ENV_FILE (mode 600, port $PROXY_PORT_CHOSEN)"
}

# --- the user's shell rc -----------------------------------------------------
#
# ~/.bashrc commonly carries the same four ANTHROPIC_* exports, added by hand
# or by an older install. If they aim at the local proxy but carry a key this
# repo did not issue, plain `claude` would use them and fail on every request.
#
# Only that case triggers a rewrite. A profile aimed at another provider, or
# already carrying our key, is the user's own; it is reported by
# check_conflicts, never changed.
migrate_shell_rc() {
  local rc="$HOME/.bashrc"
  [[ -f "$rc" ]] || return 0

  local rc_token="" rc_url=""
  rc_token="$(sed -n 's/^export ANTHROPIC_AUTH_TOKEN="\(.*\)"$/\1/p' "$rc" 2>/dev/null | head -1)"
  rc_url="$(sed -n 's/^export ANTHROPIC_BASE_URL="\(.*\)"$/\1/p' "$rc" 2>/dev/null | head -1)"
  [[ -n "$rc_token" ]] || return 0
  [[ -n "$rc_url" ]] && points_at_local_proxy "$rc_url" || return 0
  [[ "$rc_token" != "$PROFILE_TOKEN_EFFECTIVE" ]] || return 0

  # --no-rc means "do not touch my shell config", and that includes this.
  if (( ! TOUCH_RC )); then
    warn "$rc exports a stale key for the local proxy — left alone (--no-rc)."
    return 0
  fi

  if [[ -z "$PROFILE_TOKEN_EFFECTIVE" ]]; then
    warn "$rc exports a stale key for the local proxy, but there is no Token Juice"
    warn "key in $ENV_FILE to replace it with."
    return 0
  fi

  backup_if_exists "$rc"
  say "replacing the stale key in $rc with the Token Juice key from $ENV_FILE"
  if (( DRY_RUN )); then
    printf '    would rewrite the ANTHROPIC_* exports (token redacted)\n'
    return 0
  fi

  # Rewrite only the four names this project owns, and only where they already
  # exist. Anything else in the file is untouched, and the line order is kept so
  # the user's own comments stay attached to the right line.
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/zim-rc.XXXXXX")"
  if ! awk -v base="export ANTHROPIC_BASE_URL=\"http://localhost:$PROXY_PORT_CHOSEN\"" \
           -v tok="export ANTHROPIC_AUTH_TOKEN=\"$PROFILE_TOKEN_EFFECTIVE\"" \
           -v model="export ANTHROPIC_MODEL=\"$PROFILE_MODEL\"" \
           -v apikey='export ANTHROPIC_API_KEY=""' '
    /^[[:space:]]*export[[:space:]]+ANTHROPIC_BASE_URL=/  { print base;  next }
    /^[[:space:]]*export[[:space:]]+ANTHROPIC_AUTH_TOKEN=/ { print tok;   next }
    /^[[:space:]]*export[[:space:]]+ANTHROPIC_MODEL=/      { print model; next }
    /^[[:space:]]*export[[:space:]]+ANTHROPIC_API_KEY=/    { print apikey; next }
    { print }
  ' "$rc" >"$tmp"; then
    rm -f -- "$tmp"
    warn "could not rewrite $rc — leaving it as it was"
    return 0
  fi
  cat -- "$tmp" >"$rc"
  rm -f -- "$tmp"
  ok "updated $rc (port $PROXY_PORT_CHOSEN, model $PROFILE_MODEL)"
}

# --- auto-update -------------------------------------------------------------

# Record where this checkout lives and which branch it tracks, so the wrapper's
# background updater can fast-forward it. The updater reads this file; keeping
# the values out of the installed scripts means one checkout can be moved or
# re-cloned without editing anything.
#
# Auto-update is only enabled when the source really is a git checkout on a
# named branch. An unpacked tarball has nothing to pull from, and enabling it
# there would just log a failure once an hour.
#
# The file is rewritten on every install — unlike the credential profile, this
# is bookkeeping, not user data.
write_update_conf() {
  local repo="" branch="" enabled=0

  if git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    repo="$SRC_DIR"
    branch="$(git -C "$SRC_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [[ -n "$branch" ]] && enabled=1
  fi

  if (( enabled )); then
    say "auto-update: tracking origin/$branch in $repo"
  else
    say "auto-update: disabled (source is not a git checkout on a branch)"
  fi

  run mkdir -p -- "$STATE_DIR"
  run chmod 700 -- "$STATE_DIR"
  if (( DRY_RUN )); then
    printf '    would write %s (auto-update=%s, branch=%s)\n' \
      "$UPDATE_CONF" "$enabled" "${branch:-none}"
    return 0
  fi

  {
    printf '# Written by zim-claude install.sh — read by zim-claude-update.sh.\n'
    printf 'ZIM_CLAUDE_AUTO_UPDATE=%s\n' "$enabled"
    printf 'ZIM_CLAUDE_REPO_DIR=%q\n' "$repo"
    printf 'ZIM_CLAUDE_REPO_BRANCH=%q\n' "$branch"
  } >"$UPDATE_CONF"
  chmod 600 -- "$UPDATE_CONF"
}

# --- prerequisites: check, warn, ask -----------------------------------------

PREREQ_FAILED=0

# Distro detection, for install HINTS only — never for behaviour.
pkg_manager() {
  if [[ -n "${TERMUX_VERSION:-}" ]] || [[ "${PREFIX:-}" == *com.termux* ]]; then echo termux
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  elif command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  else echo unknown
  fi
}

# ask_yes <name> <display-command> — prompt only; 0 if the user agreed.
# It only asks: the caller runs the command, because the Claude Code installer
# is a shell pipeline and cannot be passed as arguments to a function.
ask_yes() {
  local name="$1" display="$2" reply=""

  # No controlling terminal (CI, piped install): never prompt, just report the
  # command. /dev/tty exists as a node even without one, so actually open it.
  # The group is required: redirections apply left-to-right, so a bare
  # `exec 3</dev/tty 2>/dev/null` would print the error before muting stderr.
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    warn "$name not found. Install with:"
    warn "  $display"
    return 1
  fi

  printf '\033[33m[!]\033[0m %s not found. Install now?\n      %s\n      [y/N] ' "$name" "$display" >&2
  read -r reply <&3 || reply=""
  exec 3<&-
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) warn "skipped $name."; return 1 ;;
  esac
}

# ask_consent <name> <what> — prompt only; 0 if the user agreed.
#
# Unlike ask_yes this never runs anything and never fails an install: it only
# asks permission for a step that is optional (building the proxy venv). With
# no controlling terminal it DECLINES — a `curl | bash` run must not silently
# download a few hundred megabytes of wheels, so a piped install skips the venv
# and says how to get it. The plain answer still works with no flag at all.
ask_consent() {
  local name="$1" what="$2" reply=""

  if ! { exec 3</dev/tty; } 2>/dev/null; then
    warn "no terminal to ask about $name — skipping."
    warn "  $what"
    return 1
  fi

  printf '\033[33m[!]\033[0m %s — %s\n      [y/N] ' "$name" "$what" >&2
  read -r reply <&3 || reply=""
  exec 3<&-
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- the proxy's own virtualenv ----------------------------------------------

# Two floors in these pins are load-bearing. Do not lower them.
#
#   litellm[proxy]>=1.100.1 — older litellm only served Anthropic /v1/messages
#     for provider == anthropic. This proxy registers its models as openai/*,
#     so the one route Claude Code actually uses returned 500 while
#     /v1/chat/completions kept working — a proxy that looks healthy.
#   uvloop>=0.22.1 — litellm hardcodes uvicorn's loop to uvloop on Linux
#     (litellm/proxy/proxy_cli.py, no flag or env var overrides it). uvloop
#     below 0.22 imports BaseDefaultEventLoopPolicy, which Python 3.14 removed,
#     so the proxy dies at startup and never binds its port.
LITELLM_REQ='litellm[proxy]>=1.100.1 uvloop>=0.22.1'

proxy_venv_has_litellm() { [[ -x "$PROXY_LITELLM" ]]; }

build_proxy_venv() {   # create the venv and install litellm into it
  run mkdir -p -- "$STATE_DIR"
  run chmod 700 -- "$STATE_DIR"
  say "creating virtualenv: $PROXY_VENV"
  run python3 -m venv "$PROXY_VENV"

  if (( DRY_RUN )); then
    printf '    would: %s -m pip install %s\n' "$PROXY_PY" "$LITELLM_REQ"
    return 0
  fi

  # Check the venv came out usable before leaning on it. This function is
  # reached through a `|| ...` at its call site, so `set -e` does not apply
  # inside it — an unchecked failure here would fall through to a pip error
  # about a missing interpreter instead of saying what actually went wrong.
  if [[ ! -x "$PROXY_PY" ]]; then
    err "python3 -m venv did not produce $PROXY_PY"
    return 1
  fi

  # Upgrade pip first: an old pip on a brand-new Python can fail to find a
  # wheel it should have. Never fatal — the install below is the real step.
  "$PROXY_PY" -m pip install --quiet --disable-pip-version-check --upgrade pip || true

  # shellcheck disable=SC2086  # LITELLM_REQ is a deliberate two-package list
  if "$PROXY_PY" -m pip install --quiet --disable-pip-version-check $LITELLM_REQ </dev/null; then
    proxy_venv_has_litellm || { err "pip finished but $PROXY_LITELLM is missing"; return 1; }
    printf '%s\n' "$LITELLM_REQ" >"$REQ_STAMP"
    ok "litellm installed into $PROXY_VENV"
    return 0
  fi
  err "could not install litellm into $PROXY_VENV"
  return 1
}

# Called only when no litellm exists anywhere. Idempotent: a venv that already
# has litellm is reported and left alone, so re-running install.sh never
# rebuilds it.
ensure_proxy_venv() {
  if (( ! DO_VENV )); then
    warn "proxy virtualenv disabled (--no-venv), and no litellm is installed."
    warn "  the proxy cannot start until you install one:"
    warn "    pipx install 'litellm[proxy]'"
    PREREQ_FAILED=1
    return 1
  fi

  if proxy_venv_has_litellm; then
    say "found litellm: $PROXY_LITELLM (existing virtualenv)"
    return 0
  fi

  if ! python3 -m venv --help >/dev/null 2>&1; then
    # Debian/Ubuntu split venv out of the interpreter package, so `python3 -m
    # venv` can be missing on a system that has python3 and pip. Name the fix
    # for this platform rather than failing with a bare traceback.
    warn "python3 has no venv module, so the proxy virtualenv cannot be built."
    case "$(pkg_manager)" in
      apt) warn "    sudo apt install python3-venv" ;;
      *)   warn "    install your platform's python3-venv package" ;;
    esac
    warn "  or install litellm yourself: pipx install 'litellm[proxy]'"
    PREREQ_FAILED=1
    return 1
  fi

  # A `curl | bash` run has no terminal: ask_consent declines and the install
  # still succeeds for the CLI side. That is the deliberate trade — an
  # unattended run must not download litellm's dependency tree unasked.
  if ! ask_consent "LiteLLM proxy virtualenv" \
       "install litellm + uvloop into $PROXY_VENV (downloads a few hundred MB)"; then
    warn "skipping the proxy virtualenv."
    warn "  the CLI works, but the proxy on :$PROXY_PORT_DEFAULT has no litellm to run."
    warn "  build it later with:  ./install.sh"
    return 1
  fi

  build_proxy_venv || { PREREQ_FAILED=1; return 1; }
}

check_prereqs() {
  local t
  for t in bash curl base64; do
    command -v "$t" >/dev/null 2>&1 || { err "required tool missing: $t"; PREREQ_FAILED=1; }
  done

  if command -v claude >/dev/null 2>&1; then
    say "found claude: $(command -v claude)"
  else
    warn "claude not found on PATH."
    # Anthropic's own installer. Preferred over `npm install -g`: no Node
    # dependency, and it sets up the launcher and shell integration itself.
    #
    # Run WITHOUT sudo on purpose. The script installs under $HOME and exits
    # with an explicit error if it detects sudo, so a sudo here would be a
    # guaranteed failure rather than a more thorough install.
    #
    # It does not put anything on PATH itself — it delegates to `claude
    # install`, which appends to ~/.bashrc / ~/.zshrc. A non-interactive
    # shell may not read those, so re-check both PATH and the usual spot.
    if ask_yes "Claude Code" "curl -fsSL https://claude.ai/install.sh | bash"; then
      say "running: curl -fsSL https://claude.ai/install.sh | bash"
      if curl -fsSL https://claude.ai/install.sh | bash; then
        ok "Claude Code installed."
      else
        warn "Claude Code install failed — continuing."
        PREREQ_FAILED=1
      fi
      if ! command -v claude >/dev/null 2>&1 && [[ -x "$BIN_DIR/claude" ]]; then
        warn "claude landed in $BIN_DIR but is not on PATH in this shell yet."
      fi
    else
      PREREQ_FAILED=1
    fi
  fi

  if command -v litellm >/dev/null 2>&1; then
    # Reuse it: a litellm that is already installed and on PATH is left exactly
    # where it is. Nothing is duplicated into the venv.
    say "found litellm: $(command -v litellm) — reusing it"
  elif [[ -x "$HOME/.local/bin/litellm" ]]; then
    say "found litellm: $HOME/.local/bin/litellm — reusing it"
  else
    # `|| ...` is load-bearing: this script runs under `set -e`, so a bare call
    # would abort the whole install the moment the venv step declines or fails.
    ensure_proxy_venv || PREREQ_FAILED=1
  fi
}

# --- PATH --------------------------------------------------------------------

ensure_path() {
  # This script is a subprocess: it cannot change the PATH of the shell that
  # launched it. So when BIN_DIR is missing, hand the user the one line that
  # fixes the CURRENT shell. ('hash -r' is not that line — it only clears the
  # command-lookup cache and never adds a directory to PATH.)
  case ":$PATH:" in
    *":$BIN_DIR:"*) say "$BIN_DIR is already on PATH" ;;
    *) warn "$BIN_DIR is not on PATH in this shell."
       warn "For THIS shell, run:"
       warn "    export PATH=\"$BIN_DIR:\$PATH\""
       warn "A new terminal will pick it up on its own." ;;
  esac

  # 1. systemd/uwsm user environment — the idiom already used by
  #    ~/.config/environment.d/local-bin.conf on Omarchy.
  if [[ -f "$ENVD_CONF" ]] && grep -qF "$BIN_DIR" "$ENVD_CONF"; then
    say "PATH already persisted in $ENVD_CONF"
  else
    say "persisting PATH for future sessions: $ENVD_CONF"
    run mkdir -p -- "$ENVD_DIR"
    if (( DRY_RUN )); then
      printf '    would append to %s: PATH=%s:$PATH\n' "$ENVD_CONF" "$BIN_DIR"
    else
      printf 'PATH=%s:$PATH\n' "$BIN_DIR" >>"$ENVD_CONF"
    fi
  fi

  # 2. ~/.bashrc marker block — secondary, covers non-uwsm shells.
  (( TOUCH_RC )) || { say "skipping shell rc (--no-rc)"; return 0; }
  local rc="$HOME/.bashrc"
  if [[ -f "$rc" ]] && grep -qF "$MARKER_BEGIN" "$rc"; then
    say "shell rc already configured"
    return 0
  fi
  backup_if_exists "$rc"
  say "adding $BIN_DIR to PATH in $rc"
  if (( DRY_RUN )); then
    printf '    would append to %s:\n' "$rc"
    printf '      %s\n      export PATH="%s:$PATH"\n      %s\n' \
      "$MARKER_BEGIN" "$BIN_DIR" "$MARKER_END"
  else
    {
      printf '\n%s\n' "$MARKER_BEGIN"
      printf '# Managed by zim-claude install.sh. Re-run install.sh to update.\n'
      printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
      printf '%s\n' "$MARKER_END"
    } >>"$rc"
  fi
}

# --- advisory conflict checks (warn only — never mutate) ---------------------

check_conflicts() {
  local rc="$HOME/.bashrc"
  # After a migration the file holds OUR values, and warning about them would
  # be noise about a conflict that no longer exists. Only report a credential
  # the installer did not put there.
  if [[ -f "$rc" ]] && grep -q 'ANTHROPIC_' "$rc" && \
     ! grep -qF "ANTHROPIC_AUTH_TOKEN=\"$PROFILE_TOKEN_EFFECTIVE\"" "$rc"; then
    warn "$rc exports ANTHROPIC_* — plain 'claude' uses that provider."
    warn "'zim-claude' overrides it. Affected lines:"
    # Redact the credential: this output is routinely pasted into a bug report.
    grep -n 'ANTHROPIC_' "$rc" \
      | sed 's/^\([0-9]*:\)export ANTHROPIC_AUTH_TOKEN=.*/\1export ANTHROPIC_AUTH_TOKEN=<redacted>/' \
      | sed 's/^/      /' >&2
  fi

  # Claude Code applies a settings.json "env" block AFTER inheriting the
  # process environment, so it would silently win over the wrapper.
  local s="$HOME/.claude/settings.json"
  if [[ -f "$s" ]] && command -v python3 >/dev/null 2>&1; then
    local keys
    keys="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print("\n".join(k for k in (d.get("env") or {}) if k.startswith("ANTHROPIC_")))
' "$s" 2>/dev/null || true)"
    if [[ -n "$keys" ]]; then
      warn "$s sets ANTHROPIC_* in its \"env\" block; that WINS over zim-claude:"
      printf '      %s\n' $keys >&2
    fi
  fi
}

# --- uninstall ---------------------------------------------------------------

do_uninstall() {
  say "uninstalling zim-claude"

  # 1. ~/.bashrc marker block
  local rc="$HOME/.bashrc"
  if [[ -f "$rc" ]] && grep -qF "$MARKER_BEGIN" "$rc"; then
    backup_if_exists "$rc"
    say "removing PATH block from $rc"
    if (( DRY_RUN )); then
      printf '    would remove the %s .. %s block\n' "$MARKER_BEGIN" "$MARKER_END"
    else
      sed -i "\|^${MARKER_BEGIN}$|,\|^${MARKER_END}$|d" "$rc"
    fi
  fi

  # 2. environment.d entry
  if [[ -f "$ENVD_CONF" ]]; then
    backup_if_exists "$ENVD_CONF"
    say "removing $ENVD_CONF"
    if (( DRY_RUN )); then
      printf '    would delete %s\n' "$ENVD_CONF"
    else
      rm -f -- "$ENVD_CONF"
    fi
  fi

  # 3. installed files — only if unmodified since install
  if [[ -f "$STATE_FILE" ]]; then
    local path mode
    while IFS=$'\t' read -r path _hash mode; do
      [[ -n "$path" ]] || continue
      if [[ ! -e "$path" ]]; then
        say "already gone: $path"; continue
      fi
      if file_is_ours "$path"; then
        say "removing $path"
        run rm -f -- "$path"
      else
        warn "modified since install — leaving: $path"
        warn "  backup from install time is under $BACKUP_ROOT"
      fi
    done <"$STATE_FILE"
  fi

  # 4. The proxy virtualenv, if we built one. The stamp is written only by
  #    build_proxy_venv, so its presence is exactly "this installer made it" —
  #    a venv the user provisioned themselves has no stamp and is left alone.
  #    (The venv is deliberately NOT in the state file: that table tracks plain
  #    files, and this is a directory.)
  if [[ -d "$PROXY_VENV" ]]; then
    if [[ -f "$REQ_STAMP" ]]; then
      say "removing the proxy virtualenv: $PROXY_VENV"
      run rm -rf -- "$PROXY_VENV"
    else
      say "keeping $PROXY_VENV (not created by this installer)"
    fi
  fi

  # 5. Never touch user data. ~/tokenjuice/ holds the credential and the
  #    model-name configuration, and other harnesses on this box use the same
  #    files, so both stay put.
  say "keeping $ENV_FILE (your credential — delete it yourself if you want)"
  say "keeping $CONFIG_FILE (the model-name configuration — shared, left alone)"
  if [[ -e "$LEGACY_ENV_FILE" || -e "$LEGACY_CONFIG_FILE" ]]; then
    say "the old layout ($LEGACY_ENV_FILE, $LEGACY_CONFIG_FILE) is no longer read;"
    say "remove it yourself when you like."
  fi

  # 6. Auto-update bookkeeping. Removing it is the point: a later wrapper from
  #    a fresh install must not inherit a stale checkout path.
  if [[ -f "$UPDATE_CONF" ]]; then
    say "removing $UPDATE_CONF"
    run rm -f -- "$UPDATE_CONF"
  fi

  (( DRY_RUN )) && return 0
  [[ -f "$STATE_FILE" ]] && rm -f -- "$STATE_FILE"
  ok "uninstalled."
}

# --- main --------------------------------------------------------------------

if (( UNINSTALL )); then
  do_uninstall
  exit 0
fi

say "zim-claude installer"
say "source:  $SRC_DIR"
say "target:  $BIN_DIR"
(( DRY_RUN )) && warn "DRY RUN — nothing will be changed"

check_prereqs

say "installing files"
install_file "$SRC_DIR/scripts/zim-claude"       "$BIN_DIR/zim-claude"       755
install_file "$SRC_DIR/scripts/start-litellm.sh" "$BIN_DIR/start-litellm.sh" 755
install_file "$SRC_DIR/scripts/zim-claude-update.sh" "$BIN_DIR/zim-claude-update.sh" 755
install_config_yaml
# A missing key is not fatal to the install: the files are in place, the user
# just has to supply the credential. Report it with the other prerequisites
# rather than aborting here, so PATH and the shell config still get set up.
install_config_env || PREREQ_FAILED=1
write_update_conf

ensure_path
migrate_shell_rc
check_conflicts

printf '\n'
if (( PREREQ_FAILED )); then
  warn "install incomplete — missing prerequisites (see above)."
fi
ok "done. Try:  zim-claude --version"
say "model configuration: $CONFIG_FILE"
say "credential profile:  $ENV_FILE"

if (( DO_START )) && [[ -x "$BIN_DIR/start-litellm.sh" ]]; then
  printf '\n'
  say "starting the LiteLLM proxy on :$PROXY_PORT_CHOSEN"
  LITELLM_PORT="$PROXY_PORT_CHOSEN" \
  LITELLM_CONFIG="$CONFIG_FILE" \
  LITELLM_ENV_FILE="$ENV_FILE" \
    "$BIN_DIR/start-litellm.sh" start \
    || warn "proxy did not start — see /tmp/litellm-proxy.log"
fi

(( PREREQ_FAILED )) && exit 1
exit 0
