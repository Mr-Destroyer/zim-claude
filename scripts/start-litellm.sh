#!/usr/bin/env bash
# start-litellm.sh — run the LiteLLM translation proxy for Claude Code
#
#   Claude Code (Anthropic /v1/messages) --▶ LiteLLM :4001 --▶ Logfare (OpenAI)
#
# Usage:  ./start-litellm.sh [start|stop|restart|status|logs|help]
#
# No secrets live here. The upstream API key is read from whatever environment
# variable the config references (api_key: os.environ/<VAR>); that variable must
# be exported by the env file sourced below.

set -euo pipefail

# --------------------------- configurable ---------------------------
ENV_FILE="${LITELLM_ENV_FILE:-$HOME/claude-source/deepseek-claude}"
CONFIG="${LITELLM_CONFIG:-$HOME/litellm-config.yaml}"
PORT="${LITELLM_PORT:-4001}"
LOG="${LITELLM_LOG:-/tmp/litellm-proxy.log}"
# Per-port, so the CLI proxy and the Claude Desktop gateway (or a second
# zim-claude install) cannot mistake each other for their own process. A shared
# pid file would let `stop` kill the other proxy.
PID_FILE="${LITELLM_PID_FILE:-/tmp/litellm-proxy-$PORT.pid}"

# Where litellm comes from, in priority order:
#   1. $LITELLM_BIN, if you set it
#   2. litellm on PATH
#   3. ~/.local/bin/litellm (a --user install, not always on PATH)
#   4. the virtualenv install.sh builds — self-contained, no system Python
# Whatever is found first wins, so an existing global litellm keeps being used
# and the venv is only a fallback.
if [[ -z "${LITELLM_BIN:-}" ]]; then
  LITELLM_BIN="$(command -v litellm 2>/dev/null || true)"
fi
if [[ -z "$LITELLM_BIN" ]]; then
  for _c in "$HOME/.local/bin/litellm" \
            "${ZIM_CLAUDE_VENV:-$HOME/.local/share/zim-claude/venv}/bin/litellm"; do
    [[ -x "$_c" ]] && LITELLM_BIN="$_c" && break
  done
fi
# --------------------------------------------------------------------

log() { printf '\033[36m[liteLLM]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[liteLLM]\033[0m %s\n' "$*" >&2; }

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
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
      log "force-killing pid $pid"
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    log "stopped."
  else
    rm -f "$PID_FILE"
    if port_answers; then
      log "no pid file, but something is still serving :$PORT — killing orphans"
      pkill -f "litellm --config $CONFIG" 2>/dev/null || true
      sleep 1
    fi
    log "not tracked as running."
  fi
}

do_start() {
  if is_running; then
    log "already running (pid $(cat "$PID_FILE")) on :$PORT."
    return 0
  fi
  if port_answers; then
    err "port :$PORT is already answering but no pid file exists."
    err "run '$0 restart' (or stop any stray 'litellm --config' process) first."
    exit 1
  fi
  [[ -x "$LITELLM_BIN" ]] || { err "litellm not found. Install it with one of:
       re-run the zim-claude installer (builds a private virtualenv), or
       pipx install 'litellm[proxy]'
     Looked on PATH, in ~/.local/bin, and in ${ZIM_CLAUDE_VENV:-$HOME/.local/share/zim-claude/venv}/bin."; exit 1; }
  [[ -f "$CONFIG" ]]      || { err "config not found: $CONFIG"; exit 1; }
  [[ -f "$ENV_FILE" ]]    || { err "env file not found: $ENV_FILE"; exit 1; }

  # Load the env file and export everything it defines (no key is echoed).
  set -a; . "$ENV_FILE"; set +a

  # Verify every os.environ/<VAR> referenced by the config is now set.
  local missing=0 var
  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    if [[ -z "${!var:-}" ]]; then
      err "required env var '$var' (referenced by config) is unset after sourcing $ENV_FILE"
      missing=1
    fi
  done < <(grep -oE 'os\.environ/[A-Za-z_][A-Za-z0-9_]*' "$CONFIG" 2>/dev/null | sed 's|os\.environ/||' | sort -u)
  if [[ "$missing" -ne 0 ]]; then exit 1; fi

  log "starting proxy on :$PORT  (config: $CONFIG)"
  log "log: $LOG"
  : > "$LOG"
  nohup "$LITELLM_BIN" --config "$CONFIG" --port "$PORT" >>"$LOG" 2>&1 </dev/null &
  echo $! > "$PID_FILE"
  disown 2>/dev/null || true

  local i
  for i in $(seq 1 30); do
    if port_answers; then
      log "up and healthy (pid $(cat "$PID_FILE")) ✓"
      return 0
    fi
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

do_help() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-start}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  status)  do_status ;;
  logs)    tail -f "$LOG" ;;
  help|-h|--help) do_help ;;
  *) err "usage: $0 [start|stop|restart|status|logs|help]"; exit 2 ;;
esac
