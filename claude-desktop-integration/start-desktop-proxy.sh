#!/usr/bin/env bash
# start-desktop-proxy.sh — dedicated LiteLLM proxy (:4002) for Claude Desktop.
#
#   Claude Desktop --> LiteLLM :4002 --> Logfare (OpenAI) --> DeepSeek
#
# Runs on its own port so it NEVER disturbs the zim-claude CLI proxy on :4000.
#
# Usage:  ./start-desktop-proxy.sh [start|stop|restart|status|logs|gateway|help]
#
# No secrets live in this file: the upstream key is read from the env profile
# (default ~/claude-source/deepseek-claude) and the gateway key from
# $CLAUDE_DESKTOP_LITELLM_KEY.

set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# --------------------------- configurable ---------------------------
ENV_FILE="${LITELLM_ENV_FILE:-$HOME/claude-source/deepseek-claude}"
CONFIG="${CLAUDE_DESKTOP_CONFIG:-$DIR/litellm-config.desktop.yaml}"
PORT="${CLAUDE_DESKTOP_PORT:-4002}"
LOG="${CLAUDE_DESKTOP_LOG:-/tmp/litellm-desktop.log}"
PID_FILE="${CLAUDE_DESKTOP_PID_FILE:-/tmp/litellm-desktop.pid}"
# Same resolution order as the CLI proxy (scripts/start-litellm.sh): an
# explicit override, then PATH, then ~/.local/bin, then the virtualenv that
# zim-claude's install.sh builds. Both proxies therefore share one litellm.
if [[ -z "${LITELLM_BIN:-}" ]]; then
  LITELLM_BIN="$(command -v litellm 2>/dev/null || true)"
fi
if [[ -z "$LITELLM_BIN" ]]; then
  for _c in "$HOME/.local/bin/litellm" \
            "${ZIM_CLAUDE_VENV:-$HOME/.local/share/zim-claude/venv}/bin/litellm"; do
    [[ -x "$_c" ]] && LITELLM_BIN="$_c" && break
  done
fi
GATEWAY_KEY="${CLAUDE_DESKTOP_LITELLM_KEY:-sk-claude-desktop-local}"
# --------------------------------------------------------------------

log() { printf '\033[36m[desktop-proxy]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[desktop-proxy]\033[0m %s\n' "$*" >&2; }

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

port_answers() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health/liveliness" --max-time 2 || true)"
  [[ "$code" == "200" ]]
}

do_stop() {
  if is_running; then
    local pid; pid="$(cat "$PID_FILE")"
    log "stopping proxy (pid $pid)..."
    kill "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    kill -0 "$pid" 2>/dev/null && { log "force-killing pid $pid"; kill -9 "$pid" 2>/dev/null || true; }
    rm -f "$PID_FILE"
    log "stopped."
  else
    rm -f "$PID_FILE"
    if port_answers; then
      log "no pid file, but :$PORT still answers — killing orphans"
      pkill -f "litellm --config $CONFIG" 2>/dev/null || true
      sleep 1
    fi
    log "not tracked as running."
  fi
}

do_start() {
  is_running && { log "already running (pid $(cat "$PID_FILE")) on :$PORT."; return 0; }
  if port_answers; then
    err "port :$PORT is answering but no pid file exists; run '$0 restart'."
    exit 1
  fi
  [[ -x "$LITELLM_BIN" ]] || { err "litellm not found. Run zim-claude's ./install.sh (builds a private virtualenv), or: pipx install 'litellm[proxy]'"; exit 1; }
  [[ -f "$CONFIG" ]]      || { err "config not found: $CONFIG"; exit 1; }
  [[ -f "$ENV_FILE" ]]    || { err "env file not found: $ENV_FILE"; exit 1; }

  # Load the profile and export everything it defines (upstream token).
  set -a; . "$ENV_FILE"; set +a
  export CLAUDE_DESKTOP_LITELLM_KEY="$GATEWAY_KEY"

  # Verify every os.environ/<VAR> the config references is now set.
  local missing=0 var
  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    [[ -n "${!var:-}" ]] || { err "required env var '$var' is unset after sourcing $ENV_FILE"; missing=1; }
  done < <(grep -oE 'os\.environ/[A-Za-z_][A-Za-z0-9_]*' "$CONFIG" 2>/dev/null | sed 's|os\.environ/||' | sort -u)
  (( missing )) && exit 1

  log "starting proxy on :$PORT  (config: $CONFIG)"
  log "gateway key for Claude Desktop: $GATEWAY_KEY"
  log "log: $LOG"
  : > "$LOG"
  nohup "$LITELLM_BIN" --config "$CONFIG" --port "$PORT" >>"$LOG" 2>&1 </dev/null &
  echo $! > "$PID_FILE"
  disown 2>/dev/null || true

  local i
  for i in $(seq 1 30); do
    if port_answers; then log "up and healthy (pid $(cat "$PID_FILE"))"; return 0; fi
    sleep 1
  done
  err "proxy did not become healthy within 30s — last log lines:"
  tail -n 20 "$LOG" >&2 || true
  exit 1
}

do_status() {
  if is_running; then
    log "running (pid $(cat "$PID_FILE")) on :$PORT"
    curl -s "http://127.0.0.1:$PORT/health/liveliness" -w ' | HTTP %{http_code}\n' --max-time 3 || echo
  else
    log "not running."
  fi
}

do_gateway() {
  # Print exactly what to paste into Claude Desktop's Third-Party Inference UI.
  cat <<EOF
Gateway base URL : http://127.0.0.1:$PORT
Gateway API key  : $GATEWAY_KEY
Auth scheme      : bearer
EOF
}

do_help() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-start}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  status)  do_status ;;
  gateway) do_gateway ;;
  logs)    tail -f "$LOG" ;;
  help|-h|--help) do_help ;;
  *) err "usage: $0 [start|stop|restart|status|logs|gateway|help]"; exit 2 ;;
esac
