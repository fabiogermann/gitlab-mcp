#!/usr/bin/env bash
# Smoke-test the stateless-mode compose stack.
#
# Sends an initialize request followed by tools/list to the round-robin
# load balancer. With stateless mode ON and OAUTH_STATELESS_SECRET shared
# across containers, both requests succeed. With stateless mode OFF, the
# second request lands on the other pod and fails with 401.
#
# Usage:
#   ./test-stateless.sh [PRIVATE_TOKEN]
#
# PRIVATE_TOKEN defaults to "smoke-test-token-aaaaaaaaaaaaaa" which only
# works against a mock GitLab. For a real GitLab, pass a valid PAT.

set -euo pipefail

LB_URL="${LB_URL:-http://127.0.0.1:3000/mcp}"
TOKEN="${1:-smoke-test-token-aaaaaaaaaaaaaa}"

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

say "Initialize (request #1) via load balancer"
init_body='{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": { "name": "stateless-smoke", "version": "1.0.0" }
  }
}'

resp1=$(curl -sS -D - -o /tmp/stateless-body1.txt -w 'HTTP_STATUS:%{http_code}\n' \
  -X POST "$LB_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Private-Token: $TOKEN" \
  --data "$init_body")

status1=$(printf '%s' "$resp1" | awk -F: '/HTTP_STATUS:/ {print $2}' | tr -d '\r\n ')
sid=$(printf '%s' "$resp1" | awk 'tolower($1) == "mcp-session-id:" {print $2}' | tr -d '\r\n')
upstream1=$(printf '%s' "$resp1" | awk 'tolower($1) == "x-upstream:" {print $2}' | tr -d '\r\n')

printf '  status=%s  upstream=%s\n' "$status1" "${upstream1:-?}"
printf '  Mcp-Session-Id=%s\n' "${sid:0:40}${sid:+…}"

[ "$status1" = "200" ] || fail "init returned status $status1 (body: $(cat /tmp/stateless-body1.txt | head -c 200))"
[ -n "$sid" ] || fail "init response had no Mcp-Session-Id header"
case "$sid" in
  v1.sid.*) printf '  \033[32mOK\033[0m: stateless sealed sid received\n' ;;
  *)        printf '  \033[33mNOTE\033[0m: non-stateless sid (%s) — stateless mode may be off on the server\n' "$sid" ;;
esac

say "tools/list (request #2) via load balancer — should land on the other pod"
list_body='{ "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {} }'

resp2=$(curl -sS -D - -o /tmp/stateless-body2.txt -w 'HTTP_STATUS:%{http_code}\n' \
  -X POST "$LB_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $sid" \
  --data "$list_body")

status2=$(printf '%s' "$resp2" | awk -F: '/HTTP_STATUS:/ {print $2}' | tr -d '\r\n ')
upstream2=$(printf '%s' "$resp2" | awk 'tolower($1) == "x-upstream:" {print $2}' | tr -d '\r\n')

printf '  status=%s  upstream=%s\n' "$status2" "${upstream2:-?}"

[ "$status2" = "200" ] || fail "tools/list returned status $status2 (body: $(cat /tmp/stateless-body2.txt | head -c 300))"

if [ -n "$upstream1" ] && [ -n "$upstream2" ]; then
  if [ "$upstream1" = "$upstream2" ]; then
    printf '  \033[33mNOTE\033[0m: both requests hit the same pod (%s) — try again to exercise the cross-pod path\n' "$upstream1"
  else
    printf '  \033[32mOK\033[0m: request #2 hit a different pod (%s vs %s) — cross-pod flow works\n' "$upstream1" "$upstream2"
  fi
fi

say "Stateless mode smoke test passed"
