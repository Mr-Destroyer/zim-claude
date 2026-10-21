# zim-claude sandbox-safe profile
# Sources your existing credentials, then redirects the proxy's log and PID
# files out of /tmp (which is read-only in sandboxed sessions).
#
# Usage:  LITELLM_ENV_FILE="$PWD/fix_env.sh" zim-claude ...

. "$HOME/claude-source/deepseek-claude"

export LITELLM_LOG="${LITELLM_LOG:-$HOME/.local/state/zim-claude/litellm-proxy.log}"
export LITELLM_PID_FILE="${LITELLM_PID_FILE:-$HOME/.local/state/zim-claude/litellm-proxy-4001.pid}"
mkdir -p "$(dirname "$LITELLM_LOG")"
