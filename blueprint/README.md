# zigens

A fast, self-contained ENS indexer and GraphQL API, written in Zig.

zigens follows ENS activity on-chain — ENS V1 (registry, registrar, NameWrapper)
and ENS V2 (registries, ETH registrar, permissions) — and serves it through a
subgraph-compatible GraphQL API, with optional live on-chain resolution for
anything not yet indexed.

## Why zigens

- **One small binary.** With embedded SQLite there are no external services:
  download, point at an RPC endpoint, run.
- **Two database backends.** The same code runs on SQLite or PostgreSQL and
  produces identical data on both.
- **The event log is the source of truth.** Every projection the API serves can
  be rebuilt from stored events with one command, byte-for-byte.
- **Subgraph-compatible.** Queries written for the ENS subgraph work unchanged;
  a golden-file conformance suite in CI keeps it that way.
- **Honest about chain reality.** Reorg handling is fail-closed, finality tiers
  are exposed per domain, and `/coverage` declares exactly what a deployment
  has indexed.

## Documentation

| Page | What it covers |
|---|---|
| [Architecture](architecture.md) | How the pieces fit: indexer, event log, projections, API |
| [Deployment](deployment.md) | Running the image or building from source; configuration |
| [API](api.md) | GraphQL surface, extensions, REST endpoints |
| [Operations](operations.md) | Probes, metrics, shutdown, rebuilds, upgrades |

## Quick start

```bash
# Run the published image (indexer + API, SQLite, Sepolia):
RPC_URL=https://your-rpc-endpoint docker compose -f docker-compose.server.yml up -d

# Or build from source (Zig 0.16+, libsqlite3):
zig build
./zig-out/bin/ensv2-indexer      # index
./zig-out/bin/ensv2-api          # serve http://localhost:8080/graphql
```
