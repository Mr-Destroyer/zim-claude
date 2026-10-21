#!/usr/bin/env bash
# install.sh — wire up the Claude Desktop (third-party inference) integration.
#
#   ./install.sh              make scripts executable, start the proxy, print steps
#   ./install.sh --no-start   do everything except starting the proxy
#   ./install.sh --managed    also write /etc/claude-desktop/managed-settings.json (sudo)
#   ./install.sh --uninstall-managed   remove the managed settings file (sudo)
#   ./install.sh --help
#
# Nothing here touches the zim-claude CLI proxy on :4000.

set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PORT="${CLAUDE_DESKTOP_PORT:-4002}"
KEY="${CLAUDE_DESKTOP_LITELLM_KEY:-sk-claude-desktop-local}"
MANAGED_DST="/etc/claude-desktop/managed-settings.json"

NO_START=0 DO_MANAGED=0 DO_UNMANAGED=0
while (($#)); do
  case "$1" in
    --no-start)          NO_START=1 ;;
    --managed)           DO_MANAGED=1 ;;
    --uninstall-managed) DO_UNMANAGED=1 ;;
    -h|--help)           sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }

# --- 0. uninstall path --------------------------------------------------------
if (( DO_UNMANAGED )); then
  if [[ -e "$MANAGED_DST" ]]; then
    say "removing $MANAGED_DST (sudo)"
    sudo rm -f "$MANAGED_DST"
    ok "removed."
  else
    warn "nothing at $MANAGED_DST"
  fi
  exit 0
fi

# --- 1. prerequisites ---------------------------------------------------------
say "checking prerequisites"
# Same resolution order as start-desktop-proxy.sh: PATH, then ~/.local/bin,
# then the virtualenv zim-claude's install.sh builds.
LITELLM_BIN="$(command -v litellm 2>/dev/null || true)"
if [[ -z "$LITELLM_BIN" && -x "$HOME/.local/bin/litellm" ]]; then
  LITELLM_BIN="$HOME/.local/bin/litellm"
fi
if [[ -z "$LITELLM_BIN" && -x "$HOME/.local/share/zim-claude/venv/bin/litellm" ]]; then
  LITELLM_BIN="$HOME/.local/share/zim-claude/venv/bin/litellm"
fi
if [[ -z "$LITELLM_BIN" ]]; then
  err "litellm not found. Run zim-claude's install.sh first (it builds a private virtualenv), or: pipx install 'litellm[proxy]'"
  exit 1
fi
ok "litellm: $LITELLM_BIN"

ENV_FILE="${LITELLM_ENV_FILE:-${ZIM_CLAUDE_TOKENJUICE_DIR:-$HOME/tokenjuice}/source}"
[[ -f "$ENV_FILE" ]] || { err "env profile missing: $ENV_FILE (run zim-claude's install.sh first)"; exit 1; }
ok "profile: $ENV_FILE"

command -v claude-desktop >/dev/null 2>&1 && ok "claude-desktop: $(command -v claude-desktop)" \
  || warn "claude-desktop not on PATH (config still valid if the app is installed)"

# The model-name config lives beside the profile, in ~/tokenjuice/. Install it
# there on first run and never touch an existing one: that directory is shared
# with the CLI route (and anything else on this box using Token Juice).
TOKENJUICE_DIR="${ZIM_CLAUDE_TOKENJUICE_DIR:-$HOME/tokenjuice}"
DESK_CONFIG="$TOKENJUICE_DIR/litellm-config.desktop.yaml"
[[ -f "$DIR/litellm-config.desktop.yaml" ]] || { err "missing $DIR/litellm-config.desktop.yaml"; exit 1; }
if [[ -f "$DESK_CONFIG" ]]; then
  say "using the desktop config already in place: $DESK_CONFIG"
else
  say "installing $DESK_CONFIG (first run — yours from now on)"
  mkdir -p -- "$TOKENJUICE_DIR"
  chmod 700 -- "$TOKENJUICE_DIR"
  install -m 644 -- "$DIR/litellm-config.desktop.yaml" "$DESK_CONFIG"
fi
ok "config: $DESK_CONFIG"

# --- 2. make scripts executable ----------------------------------------------
say "setting executable bits"
chmod +x "$DIR/start-desktop-proxy.sh" "$DIR/verify.sh"
ok "done"

# --- 3. optional managed settings --------------------------------------------
if (( DO_MANAGED )); then
  say "installing managed settings to $MANAGED_DST (sudo)"
  sudo mkdir -p /etc/claude-desktop
  sed -e "s#127.0.0.1:4002#127.0.0.1:$PORT#" -e "s#sk-claude-desktop-local#$KEY#" \
      "$DIR/managed-settings.json" | sudo tee "$MANAGED_DST" >/dev/null
  ok "written. Claude Desktop will read this on next launch."
  warn "a managed profile can trigger the app's 'managed configuration' notice — that is expected."
else
  say "managed settings NOT installed (use --managed for the no-click route, or do it in the app UI)"
fi

# --- 4. start the proxy -------------------------------------------------------
if (( NO_START )); then
  say "skipping proxy start (--no-start). Start later with: $DIR/start-desktop-proxy.sh start"
else
  say "starting the desktop proxy"
  CLAUDE_DESKTOP_PORT="$PORT" CLAUDE_DESKTOP_LITELLM_KEY="$KEY" "$DIR/start-desktop-proxy.sh" start
fi

# --- 5. instructions ----------------------------------------------------------
cat <<EOF

$(say "Point Claude Desktop at the gateway")

  In Claude Desktop:
    1. Help -> Troubleshooting -> Enable Developer Mode
    2. Claude menu -> Developer -> Configure Third-Party Inference…
    3. Connection section:
         Inference provider  : Gateway
         Gateway base URL    : http://127.0.0.1:$PORT
         Gateway API key     : $KEY
         Gateway auth scheme : bearer
    4. Apply Changes (older builds: "Apply locally"), then restart Claude Desktop.

  Model that will appear in the picker:  claude-opus-5-5

  Verify from the shell:  $DIR/verify.sh

  Heads-up: enabling third-party inference replaces the subscription
  account path for the desktop app. Flip the provider back to default
  to return to your Claude account.
EOF
