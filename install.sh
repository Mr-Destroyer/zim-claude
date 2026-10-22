#!/usr/bin/env bash
# install.sh — install the zim-claude package for the invoking user.
#
#   ./install.sh                install into $HOME
#   ./install.sh --dry-run      print every action, change nothing
#   ./install.sh --uninstall    remove what this installer created
#   ./install.sh --force        overwrite files you have hand-edited (still backs up)
#   ./install.sh --no-rc        don't touch ~/.bashrc
#   ./install.sh --help
#
# There is no local proxy any more: TokenHarbor serves the Anthropic Messages
# API itself, so this installs a wrapper, an updater and the media MCP server,
# and nothing else. No virtualenv, no LiteLLM, and no credential on disk.
#
# Everything is derived from $HOME, so this works for any user on any machine.

set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# --- what we install, and where ---------------------------------------------
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

STATE_DIR="${ZIM_CLAUDE_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zim-claude}"
STATE_FILE="$STATE_DIR/installed.tsv"
BACKUP_ROOT="$STATE_DIR/backups"
UPDATE_CONF="$STATE_DIR/update.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"

ENVD_DIR="$HOME/.config/environment.d"
ENVD_CONF="$ENVD_DIR/zim-claude.conf"
MARKER_BEGIN="# >>> zim-claude >>>"
MARKER_END="# <<< zim-claude <<<"

# The legacy LiteLLM-era install kept its virtualenv and proxy config here.
# Both are dead weight now; the stamps below are what make removing them safe.
LEGACY_VENV="$STATE_DIR/venv"
LEGACY_VENV_STAMP="$LEGACY_VENV/.litellm-req"
LEGACY_ENV_PROFILE="$HOME/claude-source/deepseek-claude"

# The media MCP server. It is dependency-free plain Node, so there is nothing
# to build and nothing to install beside the file itself.
MEDIA_DIR="$STATE_DIR/media"
MEDIA_SERVER="$MEDIA_DIR/mcp-server.mjs"
MEDIA_README="$MEDIA_DIR/README.md"

# --- flags -------------------------------------------------------------------
DRY_RUN=0 UNINSTALL=0 FORCE=0 TOUCH_RC=1

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --force)     FORCE=1 ;;
    --no-rc)     TOUCH_RC=0 ;;
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
  awk -F'\t' -v p="$1" '$1==p {h=$2; found=1} END{if (!found) exit 1; print h}' "$STATE_FILE"
}

file_is_ours() {
  local path="$1" want got
  want="$(recorded_hash "$path")" || return 1
  got="$(sha256sum -- "$path" 2>/dev/null | cut -d' ' -f1 || true)"
  [[ "$want" == "$got" ]]
}

# record_state appends, so a path installed by several runs has several rows.
# Collapse to the newest row per path, and drop rows for files this version no
# longer installs. Run AFTER the installs: file_is_ours needs the old hashes to
# still be readable while deciding whether a file is ours to overwrite.
compact_state() {
  (( DRY_RUN )) && return 0
  [[ -f "$STATE_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/zim-state.XXXXXX")"
  # Keep the newest row for each file this version actually installs; drop rows
  # for anything else, so a later --uninstall never looks for a stale path.
  awk -F'\t' -v a="$BIN_DIR/zim-claude" -v b="$BIN_DIR/zim-claude-update.sh" \
    -v c="$MEDIA_SERVER" -v d="$MEDIA_README" \
    'NF >= 3 && ($1 == a || $1 == b || $1 == c || $1 == d) { row[$1] = $0 }
     END { for (p in row) print row[p] }' \
    "$STATE_FILE" >"$tmp"
  cat -- "$tmp" >"$STATE_FILE"
  rm -f -- "$tmp"
  chmod 600 -- "$STATE_FILE"
}

# --- backups -----------------------------------------------------------------

backup_if_exists() {
  local target="$1" rel dest
  [[ -e "$target" || -L "$target" ]] || return 0
  rel="${target#"$HOME"/}"
  dest="$BACKUP_ROOT/$STAMP/${rel//\//__}"
  # One run can touch the same file twice (the PATH block and the legacy export
  # cleanup both edit ~/.bashrc). Keep the FIRST copy: it is the state before
  # this install, which is the one worth restoring.
  if [[ -e "$dest" ]]; then
    say "already backed up this run: $dest"
    return 0
  fi
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

# --- cleaning up after the LiteLLM-era install -------------------------------
#
# The previous version installed start-litellm.sh and ~/litellm-config.yaml,
# built a virtualenv, and wrote four ANTHROPIC_* exports into ~/.bashrc aimed
# at a local proxy. All of that is now wrong: nothing listens on that port any
# more, so plain `claude` in a shell would hang on a dead provider.
#
# Each removal is gated on proof of ownership — the state file's hash for a
# plain file, the .litellm-req stamp for the venv, and a Logfare token or a
# model name this repo shipped for the shell config. Anything else is reported
# and left alone.

# Files this version installs. Anything else recorded in the state file came
# from an older version and is stale.
is_current_file() {
  case "$1" in
    "$BIN_DIR/zim-claude"|"$BIN_DIR/zim-claude-update.sh"|"$MEDIA_SERVER"|"$MEDIA_README") return 0 ;;
    *) return 1 ;;
  esac
}

prune_stale_files() {
  [[ -f "$STATE_FILE" ]] || return 0
  local path hash mode found=0 seen=$'\n'
  while IFS=$'\t' read -r path hash mode; do
    [[ -n "$path" ]] || continue
    # record_state appends, so a file installed by several runs has several
    # rows. Report and remove each stale path once, not once per row.
    case "$seen" in *$'\n'"$path"$'\n'*) continue ;; esac
    seen="$seen$path"$'\n'
    is_current_file "$path" && continue
    if [[ ! -e "$path" ]]; then continue; fi
    if file_is_ours "$path"; then
      say "removing a file from the previous version: $path"
      run rm -f -- "$path"
      found=1
    else
      warn "leftover from a previous version, edited since install — leaving: $path"
    fi
  done <"$STATE_FILE"
  (( found )) && ok "old proxy files removed"
  return 0
}

remove_legacy_venv() {
  [[ -d "$LEGACY_VENV" ]] || return 0
  if [[ -f "$LEGACY_VENV_STAMP" ]]; then
    say "removing the old LiteLLM virtualenv: $LEGACY_VENV"
    run rm -rf -- "$LEGACY_VENV"
    ok "reclaimed the proxy virtualenv"
  else
    say "keeping $LEGACY_VENV (not created by this installer)"
  fi
  return 0
}

report_legacy_credential() {
  [[ -f "$LEGACY_ENV_PROFILE" ]] || return 0
  warn "$LEGACY_ENV_PROFILE is no longer read by anything."
  warn "  It holds the old Logfare key. Remove it when you like:"
  warn "    rm $LEGACY_ENV_PROFILE"
  return 0
}

# --- the media MCP server ----------------------------------------------------
#
# Claude Code can read an image, a video or an audio clip that the user
# attaches, but it cannot make one: a generated image, an edited image or a
# spoken track has to exist as a file before it can be Read. This MCP server
# provides those steps, with the local fallbacks that always work.
#
# It is dependency-free plain Node, so there is nothing to build and no
# runtime to install. Registering it with Claude Code is best effort: the
# server is still usable by anyone who starts it by hand.

install_media() {
  if [[ ! -f "$SRC_DIR/media/mcp-server.mjs" ]]; then
    warn "media/mcp-server.mjs is not in this checkout — skipping the media server"
    return 0
  fi

  run mkdir -p -- "$MEDIA_DIR"
  install_file "$SRC_DIR/media/mcp-server.mjs" "$MEDIA_SERVER" 755
  install_file "$SRC_DIR/media/README.md"       "$MEDIA_README"  644
}

# node is the only thing the server needs. Any Node from 18 up does.
find_node() {
  local n
  for n in "${ZIM_CLAUDE_NODE:-}" node nodejs; do
    [[ -n "$n" ]] || continue
    if command -v "$n" >/dev/null 2>&1; then
      command -v "$n"
      return 0
    fi
  done
  return 1
}

register_media_mcp() {
  local claude_bin node_bin out=""
  claude_bin="$(command -v claude 2>/dev/null || true)"
  if [[ -z "$claude_bin" ]]; then
    warn "claude not found — not registering the zim-media MCP server."
    warn "  Register it by hand:"
    warn "    claude mcp add zim-media --scope user -- node $MEDIA_SERVER"
    return 0
  fi

  if ! node_bin="$(find_node)"; then
    warn "node not found — not registering the zim-media MCP server."
    warn "  Register it by hand once Node is installed:"
    warn "    claude mcp add zim-media --scope user -- node $MEDIA_SERVER"
    return 0
  fi

  if (( DRY_RUN )); then
    printf '    would register the zim-media MCP server: %s %s\n' "$node_bin" "$MEDIA_SERVER"
    return 0
  fi

  # `claude mcp add` refuses to overwrite an existing entry, so remove first.
  # Removing a server that was never registered is a no-op with exit 0.
  "$claude_bin" mcp remove zim-media --scope user >/dev/null 2>&1 || true
  if out="$("$claude_bin" mcp add zim-media --scope user -- "$node_bin" "$MEDIA_SERVER" 2>&1)"; then
    if [[ "$out" == *"zim-media"* ]]; then
      ok "registered the zim-media MCP server with Claude Code"
    else
      warn "claude did not confirm the zim-media MCP server registration."
      warn "  Register it by hand:"
      warn "    claude mcp add zim-media --scope user -- node $MEDIA_SERVER"
    fi
  else
    warn "could not register the zim-media MCP server: $out"
    warn "  Register it by hand:"
    warn "    claude mcp add zim-media --scope user -- node $MEDIA_SERVER"
  fi
}

unregister_media_mcp() {
  local claude_bin
  claude_bin="$(command -v claude 2>/dev/null || true)"
  [[ -n "$claude_bin" ]] || return 0
  say "removing the zim-media MCP server from Claude Code"
  run "$claude_bin" mcp remove zim-media --scope user
}

# The four exports the old installer put in ~/.bashrc, recognised by pointing
# at a loopback proxy AND carrying a Logfare token or a model name this repo
# shipped. A shell aimed at some other provider is the user's own.
clean_legacy_shell_rc() {
  local rc="$HOME/.bashrc"
  [[ -f "$rc" ]] || return 0

  local rc_token="" rc_url=""
  rc_token="$(sed -n 's/^[[:space:]]*export ANTHROPIC_AUTH_TOKEN="\(.*\)"$/\1/p' "$rc" 2>/dev/null | head -1)"
  rc_url="$(sed -n 's/^[[:space:]]*export ANTHROPIC_BASE_URL="\(.*\)"$/\1/p' "$rc" 2>/dev/null | head -1)"

  [[ -n "$rc_token" ]] || return 0
  case "$rc_url" in
    *localhost:*|*127.0.0.1:*) ;;
    *) return 0 ;;
  esac

  # Not ours unless it is the credential or the model this repo shipped.
  case "$rc_token" in
    lfu_*) ;;
    *)
      if ! grep -qE '^[[:space:]]*export ANTHROPIC_MODEL="deepseek-v4' "$rc" 2>/dev/null; then
        return 0
      fi
      ;;
  esac

  if (( ! TOUCH_RC )); then
    warn "$rc still points plain 'claude' at a local proxy — left alone (--no-rc)."
    return 0
  fi

  backup_if_exists "$rc"
  say "removing the dead local-proxy exports from $rc"
  if (( DRY_RUN )); then
    printf '    would delete the ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL/API_KEY export lines\n'
    return 0
  fi

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/zim-rc.XXXXXX")"
  if ! awk '
    /^[[:space:]]*export[[:space:]]+ANTHROPIC_(BASE_URL|AUTH_TOKEN|MODEL|API_KEY)=/ {
      if (!noted) {
        print "# zim-claude: the local proxy these exports pointed at is gone."
        noted = 1
      }
      next
    }
    { print }
  ' "$rc" >"$tmp"; then
    rm -f -- "$tmp"
    warn "could not rewrite $rc — leaving it as it was"
    return 0
  fi
  cat -- "$tmp" >"$rc"
  rm -f -- "$tmp"
  ok "cleaned $rc (backup kept)"
}

# --- prerequisites -----------------------------------------------------------

PREREQ_FAILED=0

# ask_yes <name> <display-command> — prompt only; 0 if the user agreed.
ask_yes() {
  local name="$1" display="$2" reply=""

  # No controlling terminal (CI, piped install): never prompt, just report the
  # command. /dev/tty exists as a node even without one, so actually open it.
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

check_prereqs() {
  local t
  for t in bash curl; do
    command -v "$t" >/dev/null 2>&1 || { err "required tool missing: $t"; PREREQ_FAILED=1; }
  done

  if command -v claude >/dev/null 2>&1; then
    say "found claude: $(command -v claude)"
  else
    warn "claude not found on PATH."
    # Anthropic's own installer: no Node dependency, and it sets up the
    # launcher and shell integration itself. Run WITHOUT sudo on purpose —
    # the script installs under $HOME and exits with an error if it detects
    # sudo, so a sudo here would be a guaranteed failure.
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
  if [[ -f "$rc" ]] && grep -q 'ANTHROPIC_' "$rc"; then
    warn "$rc exports ANTHROPIC_* — plain 'claude' uses that provider."
    warn "'zim-claude' overrides it for its own process. Affected lines:"
    # Redact the credential: this output is routinely pasted into a bug report.
    grep -n 'ANTHROPIC_' "$rc" \
      | sed 's/^\([0-9]*:\)[[:space:]]*export ANTHROPIC_AUTH_TOKEN=.*/\1export ANTHROPIC_AUTH_TOKEN=<redacted>/' \
      | sed 's/^/      /' >&2
  fi

  # Claude Code applies a settings.json "env" block AFTER inheriting the
  # process environment, so it would silently win over the wrapper — and
  # TokenHarbor's own docs tell people to put a key there.
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
      warn "  remove those keys to let zim-claude supply the key per run."
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
      # awk into a temp file rather than `sed -i`: BSD sed (macOS) needs
      # `-i ''` and would otherwise eat the next argument as a backup suffix.
      local tmp
      tmp="$(mktemp "${TMPDIR:-/tmp}/zim-rc.XXXXXX")"
      if awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
           $0 == b { skip = 1; next }
           $0 == e { skip = 0; next }
           !skip
         ' "$rc" >"$tmp"; then
        cat -- "$tmp" >"$rc"
      else
        warn "could not rewrite $rc — leaving it as it was"
      fi
      rm -f -- "$tmp"
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
    local path hash mode
    while IFS=$'\t' read -r path hash mode; do
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

  # 4. The legacy proxy virtualenv, if we built it. The stamp is written only
  #    by the old installer, so its presence is exactly "we made this".
  remove_legacy_venv

  # 5. The MCP registration. The server file itself is removed by the state
  #    file above; this is the entry in Claude Code's own config.
  unregister_media_mcp

  # 6. Never touch user data or credentials.
  say "keeping $LEGACY_ENV_PROFILE (delete it yourself if you want)"
  say "keeping $STATE_DIR/last-model (your last model choice)"

  # 7. Auto-update bookkeeping. Removing it is the point: a later wrapper from
  #    a fresh install must not inherit a stale checkout path.
  if [[ -f "$UPDATE_CONF" ]]; then
    say "removing $UPDATE_CONF"
    run rm -f -- "$UPDATE_CONF"
  fi

  (( DRY_RUN )) && return 0
  [[ -f "$STATE_FILE" ]] && rm -f -- "$STATE_FILE"
  ok "uninstalled."
}

# --- auto-update -------------------------------------------------------------

# Record where this checkout lives and which branch it tracks, so the wrapper's
# background updater can fast-forward it. Auto-update is only enabled when the
# source really is a git checkout on a named branch; an unpacked tarball has
# nothing to pull from.
write_update_conf() {
  local repo="" branch="" enabled=0

  if git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    repo="$SRC_DIR"
    branch="$(git -C "$SRC_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ -n "$branch" ]]; then enabled=1; fi
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

# Before touching anything: drop what an older version left behind, so the
# state file below describes this install only.
prune_stale_files
remove_legacy_venv

say "installing files"
run mkdir -p -- "$STATE_DIR"
run chmod 700 -- "$STATE_DIR"
install_file "$SRC_DIR/scripts/zim-claude"          "$BIN_DIR/zim-claude"          755
install_file "$SRC_DIR/scripts/zim-claude-update.sh" "$BIN_DIR/zim-claude-update.sh" 755
install_media
compact_state
write_update_conf

register_media_mcp
ensure_path
clean_legacy_shell_rc
check_conflicts
report_legacy_credential

printf '\n'
if (( PREREQ_FAILED )); then
  warn "install incomplete — missing prerequisites (see above)."
fi
ok "done. Run:  zim-claude"
printf '   It will ask for a TokenHarbor API key, then show the free models.\n'
printf '   Create a key at https://tokenharbor.ai/dashboard/api-keys\n'
printf '   The zim-media MCP server is at %s\n' "$MEDIA_SERVER"

(( PREREQ_FAILED )) && exit 1
exit 0
