# OAuth and session state not shared across pods breaks HPA deployments

## Summary

When `@zereight/mcp-gitlab` runs with `STREAMABLE_HTTP=true` behind a
Kubernetes deployment with multiple replicas (HPA), OAuth flows and MCP
sessions fail whenever consecutive requests of the same logical session are
routed to different pods. All per-session state is held in per-process
memory with no shared-store abstraction and no way to survive a pod hop.

This affects `REMOTE_AUTHORIZATION=true` and every `GITLAB_MCP_OAUTH=true`
flow (both passthrough and callback-proxy modes).

## Affected version

- `@zereight/mcp-gitlab` at current `main` (2.1.4)
- Node 18+, Streamable HTTP transport

## Preconditions

- `STREAMABLE_HTTP=true`
- Multiple replicas of the server (any `HorizontalPodAutoscaler`, or any
  round-robin / least-conn load balancer in front of ≥2 processes)
- One of:
  - `REMOTE_AUTHORIZATION=true`
  - `GITLAB_MCP_OAUTH=true` (passthrough mode)
  - `GITLAB_MCP_OAUTH=true` + `GITLAB_OAUTH_CALLBACK_PROXY=true`

Traefik's built-in stickiness is cookie-based, not header-based, so
`Mcp-Session-Id` header stickiness is not natively available and does not
cover the OAuth callback endpoints anyway (they carry no MCP header).

## Reproduction

```bash
# Pod A and Pod B — same image, same config, different processes
OAUTH_VARS="STREAMABLE_HTTP=true GITLAB_MCP_OAUTH=true MCP_SERVER_URL=... GITLAB_OAUTH_APP_ID=... GITLAB_API_URL=..."

# Passthrough-mode failure
curl -X POST http://pod-A:3002/register    -d '{"redirect_uris":["https://client/cb"]}'   # returns client_id=X
curl -i  http://pod-B:3002/authorize?client_id=X&redirect_uri=...                          # 400 "Unregistered redirect_uri"

# REMOTE_AUTHORIZATION failure
# Init on A returns Mcp-Session-Id=S.
# Subsequent call on B with header Mcp-Session-Id: S → 401 "Missing Private-Token…"

# Callback-proxy failure
# /authorize on A stores pending state P in memory.
# GitLab redirects browser to /callback on B (round-robin) → 400 "Unknown or expired state parameter"
```

## Root cause

Five distinct in-memory stores on the serving pod:

| File | Symbol | Lifetime | Purpose |
|---|---|---|---|
| `oauth-proxy.ts` | `_clientCache: BoundedLRUMap` | DCR entry | written on `/register`, read on `/authorize` + `/token` |
| `oauth-proxy.ts` | `_pendingAuth: BoundedLRUMap` | 10 min | written on `/authorize`, read on `/callback` (callback-proxy mode) |
| `oauth-proxy.ts` | `_storedTokens: BoundedLRUMap` | 10 min | written on `/callback`, read on `/token` (callback-proxy mode) |
| `index.ts` | `authBySession: Record<sid, AuthData>` | `SESSION_TIMEOUT_SECONDS` | every `/mcp` request consults this |
| `index.ts` | `streamableTransports: Record<sid, Transport>` | connection | SDK transport bound to a live socket |

Each is a per-process `Map` / `Record`. Pods have no way to share them.

## Impact

- Every MCP client connecting to a multi-pod deployment fails on the first
  cross-pod hop for all three auth modes above.
- Rolling deploys, scale-in, and routine pod restarts silently invalidate
  in-flight sessions and OAuth consent windows.
- Observable symptoms: intermittent 400 / 401 responses that cannot be
  reproduced on a single-replica local deployment.

## Why header-based stickiness is not a sufficient fix

- Traefik's native stickiness is cookie-based, not header-based; rewriting
  `Mcp-Session-Id` into a sticky cookie is non-trivial and only some MCP
  clients honour cookies.
- The first `/mcp` request that creates the session carries no
  `Mcp-Session-Id` header yet — the LB cannot hash on a value the server
  is about to mint.
- Browser-driven OAuth `/callback` requests carry no `Mcp-Session-Id`
  header at all.
- Pod restart / HPA scale-in invalidates affinity regardless: the owning
  pod is gone, so stickiness points at nothing.

Shared cache (Redis / PVC) would solve it but introduces an external
dependency. A cheaper option exists.

## Proposed fix — stateless opaque tokens

Encode every piece of per-session state into the opaque OAuth values
themselves (`client_id`, OAuth `state`, OAuth `code`, `Mcp-Session-Id`)
using HMAC or AEAD keyed off a single server-side secret.

- Public payloads (DCR) use HMAC (signed).
- Secret payloads (PKCE verifier, bearer tokens) use AES-256-GCM (sealed).
- Per-purpose subkeys via HKDF from one env-var secret.
- Any pod holding the secret can verify/reconstruct state with no shared
  store and no sticky sessions.
- Backwards compatible: off by default behind `OAUTH_STATELESS_MODE=true`.

Full design, threat model, rotation runbook, and trade-offs will be in the
accompanying PR (`docs/stateless-mode.md`).

## Checklist

- [ ] Document the multi-pod failure modes
- [ ] Introduce a stateless encoding for DCR `client_id`
- [ ] Introduce a stateless encoding for callback-proxy `state` and proxy `code`
- [ ] Introduce a stateless encoding for `Mcp-Session-Id`
- [ ] Ship an opt-in `OAUTH_STATELESS_MODE` flag with no regression for
      single-replica deployments
- [ ] Cross-pod integration tests proving init-on-A → call-on-B works
