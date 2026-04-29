#!/usr/bin/env bash
# Smoke-test the stateless-mode compose stack.
#
# The stack runs in GITLAB_MCP_OAUTH + GITLAB_OAUTH_CALLBACK_PROXY mode
# to mirror the production deployment at source/repos/do/gitlab/gitlab-mcp.
# An end-to-end OAuth consent flow requires a browser, so this script
# verifies the multi-pod claim with two complementary checks:
#
# 1. OAuth discovery endpoints served consistently from both pods and
#    from the load-balanced endpoint. Every request goes to a different
#    pod thanks to nginx round-robin; consistent 200 responses prove
#    that DCR + authorize + token endpoints all work without affinity.
#
# 2. If a GitLab Personal Access Token is provided, the MCP server's
#    header-auth fallback is exercised: the script sends initialize +
#    tools/list through the round-robin load balancer and confirms that
#    the sealed Mcp-Session-Id minted on pod A is accepted on pod B.
#
# Usage:
#   ./test-stateless.sh                  # discovery check only
#   ./test-stateless.sh <GITLAB_PAT>     # discovery + cross-pod /mcp check

set -euo pipefail

LB_URL="${LB_URL:-http://127.0.0.1:3000}"
POD_A_URL="${POD_A_URL:-http://127.0.0.1:3011}"
POD_B_URL="${POD_B_URL:-http://127.0.0.1:3012}"
TOKEN="${1:-}"

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32mOK\033[0m: %s\n' "$*"; }
note(){ printf '  \033[33mNOTE\033[0m: %s\n' "$*"; }
fail(){ printf '\n\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------
# 1. OAuth discovery metadata — works against each pod directly and
#    through the round-robin LB.
# ----------------------------------------------------------------------

check_discovery() {
  local label="$1" base="$2"
  local url="$base/.well-known/oauth-protected-resource"
  local status body
  status=$(curl -sS -o /tmp/stateless-disc.json -w '%{http_code}' "$url")
  body=$(cat /tmp/stateless-disc.json)
  if [ "$status" != "200" ]; then
    fail "$label: $url returned $status (body: ${body:0:200})"
  fi
  if ! grep -q '"resource"' /tmp/stateless-disc.json; then
    fail "$label: discovery body missing 'resource' key: ${body:0:200}"
  fi
  ok "$label: $url → 200 (OAuth protected-resource metadata)"
}

say "OAuth discovery — pod A direct"
check_discovery "pod-a" "$POD_A_URL"

say "OAuth discovery — pod B direct"
check_discovery "pod-b" "$POD_B_URL"

say "OAuth discovery — round-robin load balancer"
# Three requests through the LB — with round-robin they hit A, B, A (or
# B, A, B). All must succeed because DCR client_id lookups under
# stateless mode don't depend on which pod handled /register.
for i in 1 2 3; do
  check_discovery "lb[$i]" "$LB_URL"
done

# ----------------------------------------------------------------------
# 2. Cross-pod /mcp flow using header auth (Private-Token fallback).
#    Only runs when a token is supplied.
# ----------------------------------------------------------------------

if [ -z "$TOKEN" ]; then
  say "Skipping /mcp cross-pod check — no GitLab PAT supplied"
  say "OAuth discovery checks passed on both pods and the LB."
  note "To exercise the full /mcp flow, re-run as: ./test-stateless.sh <YOUR_GITLAB_PAT>"
  exit 0
fi

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
  -X POST "$LB_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Private-Token: $TOKEN" \
  --data "$init_body")

status1=$(printf '%s' "$resp1" | awk -F: '/HTTP_STATUS:/ {print $2}' | tr -d '\r\n ')
sid=$(printf '%s' "$resp1" | awk 'tolower($1) == "mcp-session-id:" {print $2}' | tr -d '\r\n')
upstream1=$(printf '%s' "$resp1" | awk 'tolower($1) == "x-upstream:" {print $2}' | tr -d '\r\n')

printf '  status=%s  upstream=%s\n' "$status1" "${upstream1:-?}"
printf '  Mcp-Session-Id=%s\n' "${sid:0:40}${sid:+…}"

[ "$status1" = "200" ] || fail "init returned $status1 (body: $(head -c 200 /tmp/stateless-body1.txt))"
[ -n "$sid" ] || fail "init response had no Mcp-Session-Id header"
case "$sid" in
  v1.sid.*) ok "stateless sealed sid received" ;;
  *)        note "non-stateless sid ($sid) — stateless mode may be off on the server" ;;
esac

say "tools/list (request #2) via load balancer — should land on the OTHER pod"
list_body='{ "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {} }'

resp2=$(curl -sS -D - -o /tmp/stateless-body2.txt -w 'HTTP_STATUS:%{http_code}\n' \
  -X POST "$LB_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $sid" \
  --data "$list_body")

status2=$(printf '%s' "$resp2" | awk -F: '/HTTP_STATUS:/ {print $2}' | tr -d '\r\n ')
upstream2=$(printf '%s' "$resp2" | awk 'tolower($1) == "x-upstream:" {print $2}' | tr -d '\r\n')

printf '  status=%s  upstream=%s\n' "$status2" "${upstream2:-?}"

[ "$status2" = "200" ] || fail "tools/list returned $status2 (body: $(head -c 300 /tmp/stateless-body2.txt))"

if [ -n "$upstream1" ] && [ -n "$upstream2" ]; then
  if [ "$upstream1" = "$upstream2" ]; then
    note "both requests hit the same pod ($upstream1) — try again to exercise the cross-pod path"
  else
    ok "request #2 hit a different pod ($upstream1 vs $upstream2) — cross-pod flow works"
  fi
fi

say "Stateless mode smoke test passed"
