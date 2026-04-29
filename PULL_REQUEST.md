# feat: stateless OAuth / session mode for multi-pod HPA deployments

Closes #<ISSUE_NUMBER>

## Summary

Adds an opt-in `OAUTH_STATELESS_MODE` that makes the OAuth proxy, DCR
registry, and `Mcp-Session-Id` path safe to distribute across multiple
pods with **no external cache, no sticky sessions, and no affinity
requirement**. All per-session state travels on the wire as a signed or
AEAD-sealed opaque value, keyed off a single shared secret.

Default behaviour (`OAUTH_STATELESS_MODE=false`) is bit-identical to
before. Single-replica and stdio deployments are unaffected.

## The problem (see linked issue)

Today's code holds five in-memory stores per pod:

| Surface | Today | Problem under HPA |
|---|---|---|
| DCR `_clientCache` | `BoundedLRUMap` on pod | `/register` on A, `/authorize` on B ⇒ 400 |
| Callback-proxy `_pendingAuth` | `BoundedLRUMap` on pod | `/authorize` on A, `/callback` on B ⇒ 400 |
| Callback-proxy `_storedTokens` | `BoundedLRUMap` on pod | `/callback` on A, `/token` on B ⇒ 400 |
| `/mcp` `authBySession` | `Record<sid, AuthData>` on pod | init on A, tool call on B ⇒ 401 |
| Rate-limit counters | per-pod | N× configured limit under LB |

Header-based stickiness on `Mcp-Session-Id` does not fix it: Traefik is
cookie-based, the header is absent on init and on all OAuth callback
endpoints, and pod restart / scale-in invalidates affinity regardless.

## Fix

Encode each piece of per-session state into the opaque OAuth value
itself, using HMAC or AEAD keyed off a per-purpose subkey derived from
one master secret:

```
signed:   v1.<purpose>.<b64url(payload)>.<b64url(hmac)>
sealed:   v1.<purpose>.<b64url(nonce || ciphertext || tag)>
```

| Surface | After |
|---|---|
| DCR `client_id` | Signed (`v1.cid.…`) — public payload |
| OAuth `state` | Sealed (`v1.ps.…`) — contains proxy PKCE verifier |
| Proxy `code` | Sealed (`v1.pc.…`) — contains GitLab tokens |
| `Mcp-Session-Id` | Sealed (`v1.sid.…`) — contains bearer token |
| Rate-limit | Disabled in stateless mode (documented); apply upstream |

Cryptography:
- HMAC-SHA256 (signed) or AES-256-GCM (sealed), Node built-in `crypto`
- Per-purpose subkeys via HKDF-SHA256 — a token minted for one purpose
  cannot be verified as another
- 12-byte nonce, 16-byte tag, purpose as AEAD AAD
- Two-slot keyring for rotation
  (`OAUTH_STATELESS_SECRET` + `OAUTH_STATELESS_SECRET_PREVIOUS`)

## What reviewers should look at

- `stateless/` — new module (codec, secret, four purpose-specific helpers)
- `oauth-proxy.ts` — clientsStore, `authorize()`, `handleCallback()`,
  `exchangeAuthorizationCode()` each gain a stateless branch; legacy
  BoundedLRUMap path retained
- `index.ts` — new `handleStatelessMcpRequest` helper short-circuits
  ahead of the legacy `authBySession` / `streamableTransports` logic
- `config.ts` — six new env vars
- `docs/stateless-mode.md` — operator guide with threat model and
  rotation runbook

## Configuration

```bash
OAUTH_STATELESS_MODE=true
OAUTH_STATELESS_SECRET=$(openssl rand -base64 32)    # same on every pod
# optional:
OAUTH_STATELESS_SECRET_PREVIOUS=...                  # rotation
OAUTH_STATELESS_CLIENT_TTL_SECONDS=86400             # default 24h
OAUTH_STATELESS_PENDING_TTL_SECONDS=600              # default 10min
OAUTH_STATELESS_STORED_TTL_SECONDS=600               # default 10min
OAUTH_STATELESS_SESSION_TTL_SECONDS=3600             # defaults to SESSION_TIMEOUT_SECONDS
```

In Kubernetes, mount `OAUTH_STATELESS_SECRET` from a `Secret` resource
identical across all pods.

## Security model

| Value | Compromise impact | Mitigation |
|---|---|---|
| `client_id` | None (public) | — |
| OAuth `state` | Useless alone (GitLab code is single-use) | 10-min TTL |
| Proxy `code` | Contains GitLab access token | 10-min TTL + PKCE `code_verifier` check at `/token` |
| `Mcp-Session-Id` | Equivalent to stolen bearer token | TLS, log redaction (added in this PR), inactivity TTL |
| `OAUTH_STATELESS_SECRET` | Total forgery | Treat as bearer secret, K8s Secret with access audit |

Rotation: set `OAUTH_STATELESS_SECRET_PREVIOUS=<old>`, deploy, remove
after `max(TTL)` elapses. Omitting `_PREVIOUS` invalidates all
outstanding tokens immediately — the intended emergency response.

## Backward compatibility

- `OAUTH_STATELESS_MODE=false` (default): zero behaviour change. The
  existing BoundedLRUMap and `authBySession` paths are retained and
  selected at runtime.
- Legacy UUID client_ids and session_ids still flow through the legacy
  stubs in the provider, so pre-existing GitLab app UIDs and any
  mid-flight sessions from older pods continue to work as before.
- No new runtime dependencies. All crypto uses Node's built-in module.

## Testing

**69 new tests**, all passing:

```
Phase 1 codec               34  unit
Phase 2 client-id cross-pod 10  integration (2 provider instances)
Phase 3 callback-proxy       12  integration (3 provider instances)
Phase 4 session-id            8  unit
Phase 4 session-id integ.     5  integration (2 spawned server processes)
                             --
                             69  total new
```

**Full `npm run test:mock`** now runs 190 tests (up from 121), 0 failures:

```
$ npm run test:mock
…
TOTAL tests in test:mock: 190
passes counted: 243
fails counted:   0
```

Specifically:
- Existing `test/mcp-oauth-tests.ts` — 17/17 pass (no regression)
- Existing `test/remote-auth-simple-test.ts` — 7/7 pass (no regression)
- New `test/stateless/session-id-integration.test.ts` launches two
  separate MCP server processes sharing only `OAUTH_STATELESS_SECRET`
  and proves init on pod A → `tools/list` on pod B works end-to-end

`test:live` is intentionally skipped here; it requires a live GitLab and
is unaffected by these changes.

## Commits

30 small commits organised by phase, each revertable independently:

```
phase 0  docs: add STATELESS-MODE-PLAN.md
phase 1  codec, secret keyring, HKDF + 34 unit tests
phase 2  signed client_id + DCR wiring + 10 cross-pod tests
phase 3  sealed state + sealed proxy code + callback-proxy wiring + 12 tests
phase 4  sealed Mcp-Session-Id + /mcp wiring + 13 tests
phase 5  docs: operator guide, env-vars ref, README, callback-proxy doc
phase 6  pino log redaction, /metrics counters, test:mock integration
```

Each phase ends with a `chore(stateless): phase N summary` empty commit
for readability.

## Deliberately out of scope

- **`StreamableHTTPServerTransport` object affinity.** The transport owns
  a live TCP socket and cannot be serialised. Documented as a deployment-
  level concern (cookie stickiness in Traefik, header-hashing in Nginx /
  Envoy, or accepting dropped notifications on pod hop).
- **Global rate limiting across pods.** Per-pod counters in stateless
  mode would give a loose N× bound; operators should rate-limit at the
  ingress or WAF.
- **One-time-use for sealed proxy codes.** Not enforceable without a
  shared store. The PKCE `code_verifier` check at `/token` plus the
  10-minute TTL provides the equivalent practical guarantee, at parity
  with RFC 6749's authorization-code model.

## Review checklist

- [ ] Read `docs/stateless-mode.md` and the threat model
- [ ] Skim `stateless/` — codec, keyring, four purpose helpers
- [ ] Check `oauth-proxy.ts` diff — stateless branch + legacy path
      retained under the same interface
- [ ] Check `index.ts` diff — `handleStatelessMcpRequest` short-circuits
      before the legacy block
- [ ] Run `npm run test:mock` locally (190 tests, ~60s)
- [ ] Confirm no change when `OAUTH_STATELESS_MODE` is unset / false
