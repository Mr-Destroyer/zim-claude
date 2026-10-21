#!/usr/bin/env bash
# verify.sh — prove the Claude Desktop gateway is reachable and behaving.
#
# Exercises the same two endpoints Claude Desktop uses:
#   GET  /v1/models    (model discovery / picker)
#   POST /v1/messages  (Anthropic Messages API, streaming + tool use)
#
# Usage: ./verify.sh [model-name]

set -euo pipefail

PORT="${CLAUDE_DESKTOP_PORT:-4002}"
KEY="${CLAUDE_DESKTOP_LITELLM_KEY:-sk-claude-desktop-local}"
MODEL="${1:-claude-opus-5-5}"
BASE="http://127.0.0.1:$PORT"

pass() { printf '\033[32m  ok\033[0m  %s\n' "$*"; }
fail() { printf '\033[31m fail\033[0m  %s\n' "$*"; }
hdr()  { printf '\033[36m==>\033[0m %s\n' "$*"; }

hdr "1. proxy health ($BASE/health/liveliness)"
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health/liveliness" --max-time 5 || true)"
[[ "$code" == "200" ]] && pass "healthy (HTTP $code)" || { fail "HTTP $code — is the proxy running? try ./start-desktop-proxy.sh start"; exit 1; }

hdr "2. model discovery ($BASE/v1/models)"
body="$(curl -s "$BASE/v1/models" -H "Authorization: Bearer $KEY" --max-time 8 || true)"
echo "    $body"
echo "$body" | grep -q 'claude' \
  && pass "picker will show claude-* model(s)" \
  || fail "no claude/anthropic-named model — Claude Desktop would reject the deployment"

hdr "3. Anthropic Messages API (POST $BASE/v1/messages, model=$MODEL)"
code="$(curl -s -o /tmp/_verify_msg.json -w '%{http_code}' -X POST "$BASE/v1/messages" \
  -H "content-type: application/json" \
  -H "x-api-key: $KEY" \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ready\"}]}" \
  --max-time 45 || true)"
if [[ "$code" == "200" ]]; then
  pass "HTTP 200"
  head -c 400 /tmp/_verify_msg.json; echo
else
  fail "HTTP $code"
  head -c 600 /tmp/_verify_msg.json; echo
fi

cat <<EOF

$(hdr "Next: point Claude Desktop at this gateway")
  Developer menu -> Configure Third-Party Inference…
    Inference provider : Gateway
    Gateway base URL   : $BASE
    Gateway API key    : $KEY
    Gateway auth scheme: bearer
  Apply, then restart Claude Desktop.
EOF
