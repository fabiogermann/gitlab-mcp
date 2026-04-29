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

A second compose file is shipped to reproduce the HPA-style scenario
that stateless mode is designed to fix. It spins up **two** gitlab-mcp
containers that share `OAUTH_STATELESS_SECRET` and sit behind an nginx
round-robin load balancer, so consecutive requests of one MCP session
land on different containers.

```bash
cd docker
cp .env.stateless.example .env.stateless
# edit .env.stateless — at minimum set GITLAB_API_URL and a secret:
#   OAUTH_STATELESS_SECRET=$(openssl rand -base64 32)

docker compose -f docker-compose.stateless.yaml --env-file .env.stateless up
```

Endpoints once up:

| URL                            | What                                |
| ------------------------------ | ----------------------------------- |
| `http://127.0.0.1:3000/mcp`    | Load-balanced MCP endpoint          |
| `http://127.0.0.1:3011/metrics`| Pod A metrics (direct)              |
| `http://127.0.0.1:3012/metrics`| Pod B metrics (direct)              |

Run the bundled smoke test to prove the cross-pod flow:

```bash
./test-stateless.sh <YOUR_GITLAB_PAT>
```

The script sends an `initialize` request and a follow-up `tools/list`
through the load balancer, checks the response status, shows which
upstream served each request (via the `X-Upstream` header nginx adds),
and confirms that the returned `Mcp-Session-Id` is a stateless sealed
value (`v1.sid.…`).

To see the stateless flow from the server side, turn the log level up:

```bash
LOG_LEVEL=debug docker compose -f docker-compose.stateless.yaml \
  --env-file .env.stateless up
```

Each request will emit one `stateless /mcp request` line containing
the redacted sid prefix, the auth source (header vs sealed sid), and
the header type. No tokens are logged.

### Pinning to a specific image tag

By default the stack pulls `ghcr.io/fabiogermann/gitlab-mcp:latest`.
Point at an immutable SHA tag (the one the CI workflow publishes) by
setting `GITLAB_MCP_IMAGE` in `.env.stateless`:

```bash
GITLAB_MCP_IMAGE=ghcr.io/fabiogermann/gitlab-mcp:<40-char-sha>
```
