#!/usr/bin/env bash
# install.sh — install the zim-claude package for the invoking user.
#
#   ./install.sh                install into $HOME
#   ./install.sh --dry-run      print every action, change nothing
#   ./install.sh --uninstall    remove what this installer created
#   ./install.sh --force        overwrite files you have hand-edited (still backs up)
#   ./install.sh --no-rc        don't touch ~/.bashrc
#   ./install.sh --start        start the LiteLLM proxy when done
#   ./install.sh --help
#
# Everything is derived from $HOME, so this works for any user on any machine.

set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# --- what we install, and where ---------------------------------------------
# Config paths are fixed at $HOME (not under $PREFIX): start-litellm.sh ships
# verbatim and its built-in defaults point at exactly these locations.
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

HOME_SRC_DIR="$HOME/claude-source"
ENV_FILE="$HOME_SRC_DIR/deepseek-claude"
CONFIG_FILE="$HOME/litellm-config.yaml"

STATE_DIR="$HOME/.local/share/zim-claude"
STATE_FILE="$STATE_DIR/installed.tsv"
BACKUP_ROOT="$STATE_DIR/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"

ENVD_DIR="$HOME/.config/environment.d"
ENVD_CONF="$ENVD_DIR/zim-claude.conf"
MARKER_BEGIN="# >>> zim-claude >>>"
MARKER_END="# <<< zim-claude <<<"

# --- flags -------------------------------------------------------------------
DRY_RUN=0 UNINSTALL=0 FORCE=0 TOUCH_RC=1 DO_START=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --force)     FORCE=1 ;;
    --no-rc)     TOUCH_RC=0 ;;
    --start)     DO_START=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

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
  awk -F'\t' -v p="$1" '$1==p {print $2; found=1} END{exit !found}' "$STATE_FILE"
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

# The env file is special: it holds a live credential, so it is never
# overwritten — not even with --force. Losing it would mean re-issuing a token.
install_config_env() {
  run mkdir -p -- "$HOME_SRC_DIR"
  run chmod 700 -- "$HOME_SRC_DIR"

  if [[ -e "$ENV_FILE" ]]; then
    say "keeping existing env file: $ENV_FILE (never overwritten)"
    run chmod 600 -- "$ENV_FILE"
    return 0
  fi

  # Plaintext token file. Trims surrounding whitespace, including the CR that
  # a Windows checkout or a copy-paste through a browser adds — a trailing CR
  # would otherwise end up inside the export and break authentication with a
  # 401 that looks like a bad key.
  local token="" src=""
  if [[ -f "$SRC_DIR/config/token" ]]; then
    src="$SRC_DIR/config/token"
    token="$(tr -d ' \t\r\n' < "$src" || true)"
  elif [[ -f "$SRC_DIR/config/.token.b64" ]]; then
    # Legacy layout: base64 blob. Kept so an existing checkout still installs.
    src="$SRC_DIR/config/.token.b64"
    token="$(base64 -d < "$src" 2>/dev/null | tr -d ' \t\r\n' || true)"
  fi

  if [[ -z "$token" ]]; then
    err "no token found in $SRC_DIR/config/"
    err "  expected $SRC_DIR/config/token to hold the ANTHROPIC_AUTH_TOKEN"
    return 1
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
export ANTHROPIC_BASE_URL="http://localhost:4000"
export ANTHROPIC_AUTH_TOKEN="$token"
export ANTHROPIC_MODEL="deepseek-v4.1-flash"
export ANTHROPIC_API_KEY=""
EOF
  chmod 600 -- "$ENV_FILE"
  ok "wrote $ENV_FILE (mode 600)"
}

# --- prerequisites: check, warn, ask -----------------------------------------

PREREQ_FAILED=0

ask_install() {   # ask_install <name> <command...>
  local name="$1"; shift
  local reply=""

  # No controlling terminal (CI, piped install): never prompt, just report the
  # command. /dev/tty exists as a node even without one, so actually open it.
  # The group is required: redirections apply left-to-right, so a bare
  # `exec 3</dev/tty 2>/dev/null` would print the error before muting stderr.
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    warn "$name not found. Install with:"
    warn "  $*"
    return 1
  fi

  printf '\033[33m[!]\033[0m %s not found. Install now?\n      %s\n      [y/N] ' "$name" "$*" >&2
  read -r reply <&3 || reply=""
  exec 3<&-
  case "$reply" in
    [yY]|[yY][eE][sS])
      say "running: $*"
      if "$@"; then ok "$name installed."; return 0
      else warn "$name install failed — continuing."; return 1; fi
      ;;
    *) warn "skipped $name."; return 1 ;;
  esac
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
    ask_install "Claude Code" npm install -g @anthropic-ai/claude-code || PREREQ_FAILED=1
  fi

  if command -v litellm >/dev/null 2>&1; then
    say "found litellm: $(command -v litellm)"
  elif [[ -x "$HOME/.local/bin/litellm" ]]; then
    say "found litellm: $HOME/.local/bin/litellm (not currently on PATH)"
  else
    warn "litellm not found."
    ask_install "litellm" \
      python3 -m pip install --user --break-system-packages 'litellm[proxy]' || PREREQ_FAILED=1
  fi
}

# --- PATH --------------------------------------------------------------------

ensure_path() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) say "$BIN_DIR is already on PATH" ;;
    *) warn "$BIN_DIR is not on PATH in this shell — start a new terminal,"
       warn "or run 'hash -r' if you have already installed before." ;;
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
  if [[ -f "$rc" ]] && grep -q 'ANTHROPIC_' "$rc"; then
    warn "$rc exports ANTHROPIC_* — plain 'claude' uses that provider."
    warn "'zim-claude' overrides it. Affected lines:"
    grep -n 'ANTHROPIC_' "$rc" | sed 's/^/      /' >&2
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

  # 4. Never touch user data. The env file is a credential and
  #    ~/claude-source/ may also hold unrelated profiles, so both stay put.
  say "keeping $ENV_FILE (your credential — delete it yourself if you want)"
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
install_file "$SRC_DIR/config/litellm-config.yaml" "$CONFIG_FILE"            644
install_config_env

ensure_path
check_conflicts

printf '\n'
if (( PREREQ_FAILED )); then
  warn "install incomplete — missing prerequisites (see above)."
fi
ok "done. Try:  zim-claude --version"

if (( DO_START )) && [[ -x "$BIN_DIR/start-litellm.sh" ]]; then
  printf '\n'
  say "starting the LiteLLM proxy"
  "$BIN_DIR/start-litellm.sh" start || warn "proxy did not start — see /tmp/litellm-proxy.log"
fi

(( PREREQ_FAILED )) && exit 1
exit 0
