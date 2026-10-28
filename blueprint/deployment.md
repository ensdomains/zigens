# Deployment

## Run the published image

```bash
RPC_URL=https://your-rpc-endpoint \
docker compose -f docker-compose.server.yml up -d
```

This starts the V2 indexer and the API (port 5655) on embedded SQLite with a
shared volume. Pin a version in production: `ZIGENS_IMAGE=ghcr.io/mdtanrikulu/zigens:0.1.0`.
The other compose files (`docker-compose.yml`, `docker-compose.staging.yml`)
build the image from source instead.

## Build from source

Requirements: Zig 0.16+, libsqlite3 (`libsqlite3-dev` on Debian/Ubuntu;
on macOS, prefix builds with `PKG_CONFIG_PATH=/opt/homebrew/opt/sqlite/lib/pkgconfig:$PKG_CONFIG_PATH`).

```bash
zig build                        # all binaries -> zig-out/bin/
zig build test-all               # full test suite (SQLite lanes)
```

| Binary | Purpose |
|---|---|
| `ensv2-indexer` | Combined V1 + V2 indexer |
| `ensv2-indexer-v1` / `-v2` | Single-protocol indexers |
| `ensv2-api` | GraphQL / REST API server |
| `rainbow-backfill` | Label-healing backfill from rainbow tables |

A plain `zig build` also installs small dev tools; `zig build -Dtools=false`
(what the Docker image uses) skips them.

## Configuration

Everything is environment variables; `.env` in the working directory is loaded
automatically. `.env.example` (Sepolia) and `.env.mainnet.example` document the
full surface. The ones that matter first:

| Variable | Meaning |
|---|---|
| `RPC_URL` | Ethereum JSON-RPC endpoint (defaults to a local node at `localhost:8545`) |
| `NETWORK` | `sepolia` or `mainnet` |
| `DATABASE_PATH` | SQLite file (default backend) |
| `DATABASE_URL` | `postgres://…` — switches the backend to PostgreSQL |
| `INDEXER_DATABASE_URL` / `API_DATABASE_URL` | Per-service override of `DATABASE_URL`; both default to it |
| `START_BLOCK` | First block on a *fresh* database (default: the network's V1 deployment block; ignored once sync state exists — use `--from-block` to re-index) |
| `API_PORT` | API listen port (default 8080) |
| `RATE_LIMIT_PER_SECOND` | Indexer's outbound RPC budget, and the API's per-IP request limit (default 15) |
| `MANIFEST_PATH` | Optional `.zon` contract manifest (redeploys without recompiling) |
| `FINALITY_ENABLED` | Track safe/finalized tiers (recommended in production) |
| `MCP_ENABLED` | Agent endpoint at `POST /mcp` — see [API](api.md#mcp-agents) (default off) |
| `MCP_ALLOWED_ORIGINS` | Browser origins allowed to call `POST /mcp`; non-browser clients unaffected (default: none) |
| `RPC_BACKPRESSURE_ENABLED` | Halve the outbound RPC rate while the provider throttles, recovering when it goes quiet (default on) |

## Choosing a backend

- **SQLite** (default): zero dependencies, one file, ideal for single-node
  deployments. Use `SQLITE_JOURNAL_MODE=DELETE` on network/FUSE filesystems.
- **PostgreSQL**: for managed infrastructure. TLS is built into the image
  (`sslmode=require` in the URL). **Both services can run pooled on stock pooler
  settings, and one `DATABASE_URL` is enough for both.** The driver sends each statement
  as a single `Parse`+`Bind`+`Describe`+`Execute`+`Sync` message group, so nothing it
  creates outlives the group and a transaction-mode pooler has no per-connection state to
  lose. Measured: the API served 3200 concurrent requests through PgDog 0.1.26 with 0
  errors (the previous driver failed 176 of 320, SQLSTATE 08P01/26000 — and silently
  wrong rows when two colliding statements took the same parameter count), and the
  indexer produced **byte-identical data across all 51 tables** when the same block range
  was indexed direct and through the pooler (V1 mainnet 131,820 events; V2 Sepolia 26,856
  events). No `prepared_statements` tuning, no `pooler_mode = "session"`, no
  direct-endpoint requirement.
  `INDEXER_DATABASE_URL` and `API_DATABASE_URL` remain available, but only for
  operational reasons — separate credentials (the read-only API role), a different
  endpoint per service, or connection isolation. Each falls back to `DATABASE_URL`.
  Whether a connection-scoped `SET` (e.g. `statement_timeout`) survives is a separate,
  pooler-specific question: pgbouncer drops it, PgDog virtualises it. Put the timeout
  where neither can lose it — on the role, or enforced by the pooler per user. There is a
  best-effort startup probe, but it only sees the session-state half and stays quiet on
  poolers that virtualise session parameters (PgDog does) — so silence is not a clean
  bill of health.

Whichever you pick, the data is equivalent — the rebuild command produces
identical projections on both.

## Network notes

- **Sepolia** and **mainnet** both index ENS V1 and V2. Mainnet V2 indexing
  starts at the October 2026 deployment (block 26105294).
- Label healing uses a rainbow table (~6 GB). Containers running the combined
  or V1 indexer download it on first start (`DOWNLOAD_RAINBOW=true`) or reuse a
  copy via `RAINBOW_PATH`; the V2-only indexer (what
  `docker-compose.server.yml` runs) skips it — V2 events carry their labels.
