# Start GitLab MCP Server with Docker Compose


## Starting the server
### 1. Set up environment variables

```bash
# in root
cd docker

cp .env.example .env
```

### 2. Override environment variables



### 3. Start with Docker Compose

```bash
docker compose up -d
```


## Upgrade the server

```bash
cd docker
docker compose down
git pull origin main
docker compose pull
docker compose up -d
```

## Multi-pod stateless-mode test bench

Mirrors the production deployment at
`source/repos/do/gitlab/gitlab-mcp` — same auth mode
(`GITLAB_MCP_OAUTH` + `GITLAB_OAUTH_CALLBACK_PROXY`), same upstream
GitLab contract — but replaces Traefik cookie stickiness with **no
affinity at all**, which is what stateless mode makes safe.

Spins up **two** gitlab-mcp containers sharing
`OAUTH_STATELESS_SECRET` behind an nginx round-robin load balancer, so
consecutive requests of one MCP session deterministically land on
different containers.

```bash
cd docker
cp .env.stateless.example .env.stateless
# edit .env.stateless — at minimum set:
#   OAUTH_STATELESS_SECRET   (openssl rand -base64 32)
#   GITLAB_API_URL           (e.g. https://gitserver.warrantymaster.com/api/v4)
#   MCP_SERVER_URL           (public URL of the MCP endpoint)
#   GITLAB_OAUTH_APP_ID      (GitLab OAuth app client_id, redirect URI
#                             must be <MCP_SERVER_URL>/callback)

docker compose -f docker-compose.stateless.yaml --env-file .env.stateless up
```

Endpoints once up:

| URL                                              | What                                 |
| ------------------------------------------------ | ------------------------------------ |
| `http://127.0.0.1:3000/mcp`                      | Load-balanced MCP endpoint           |
| `http://127.0.0.1:3000/.well-known/oauth-*`      | OAuth discovery (via LB)             |
| `http://127.0.0.1:3011/metrics`                  | Pod A metrics (direct)               |
| `http://127.0.0.1:3012/metrics`                  | Pod B metrics (direct)               |

Run the bundled smoke test:

```bash
./test-stateless.sh                  # OAuth discovery consistency only
./test-stateless.sh <YOUR_GITLAB_PAT> # discovery + cross-pod /mcp flow
```

What the smoke test checks:

1. **OAuth discovery from each pod and through the LB.** Three requests
   through the LB hit both pods via round-robin; all must return the
   same protected-resource metadata. This proves DCR works across pods
   without affinity.
2. **Cross-pod /mcp flow** (when a PAT is supplied). Sends `initialize`
   → LB → pod A, followed by `tools/list` with the returned
   `Mcp-Session-Id` → LB → pod B. Both succeed only because pod B can
   open the sealed sid with the shared secret.

To see the stateless flow from the server side, turn the log level up:

```bash
LOG_LEVEL=debug docker compose -f docker-compose.stateless.yaml \
  --env-file .env.stateless up
```

Each request emits one `stateless /mcp request` line with the redacted
sid prefix, the auth source (header vs sealed sid), and the header
type. No tokens are logged.

### Completing the OAuth flow end-to-end

The smoke test above verifies the infrastructure. To exercise the full
OAuth consent flow with a real MCP client:

1. Point your MCP client (Claude Desktop, Claude.ai, MCP Inspector,
   etc.) at `http://127.0.0.1:3000/mcp` (or a public URL if you
   reverse-proxy this stack).
2. Confirm `MCP_SERVER_URL` matches what the client sees.
3. In GitLab, register an OAuth application with redirect URI
   `<MCP_SERVER_URL>/callback` and set `GITLAB_OAUTH_APP_ID`
   accordingly.
4. Start the client. It will walk you through the GitLab consent
   screen. The browser redirect can land on either pod thanks to
   round-robin — stateless mode makes that work without stickiness.

### Pinning to a specific image tag

By default the stack pulls `ghcr.io/fabiogermann/gitlab-mcp:latest`.
Point at an immutable SHA tag (the one the CI workflow publishes) by
setting `GITLAB_MCP_IMAGE` in `.env.stateless`:

```bash
GITLAB_MCP_IMAGE=ghcr.io/fabiogermann/gitlab-mcp:<40-char-sha>
```
