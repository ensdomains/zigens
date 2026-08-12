# ENS Indexer (zigens)

A high-performance indexer for the Ethereum Name Service — **both ENS V1 (legacy) and ENS V2** —
written in Zig on SQLite or PostgreSQL, with a subgraph-compatible GraphQL API.

It follows ENS contract events, derives the current state of names, registrations, resolver records,
roles and accounts, survives chain reorganizations, and serves everything over a GraphQL endpoint
that works with existing ensjs / ENS-subgraph / Apollo clients.

## Features

### Indexing
- Indexes **ENS V1 (legacy registry, registrar, name wrapper)** and **ENS V2 (permissioned
  registry)** side by side in one database.
- Tracks registrations, ownership and transfers, resolver records (addresses, text, contenthash,
  DNS, ABI, pubkey…), wrapper state and fuses, access-control roles, and reverse records.
- Discovers new subregistries and resolvers automatically from on-chain events.
- Recovers human-readable labels via a rainbow table (with a backfill tool for missing ones).
- **Reorg-safe:** detects chain reorganizations and rolls the database back cleanly.

### GraphQL API
- Subgraph-compatible schema — drop-in for many existing ENS clients.
- Rich filtering, including `and` / `or` boolean conditions. List queries return only
  **normalized, reachable names** by default — opt in to the rest with `includeUnnormalized: true`.
- Offset (`first`/`skip`) and Relay cursor pagination; connection cursors are **opaque keyset
  tokens** (treat them as opaque — don't hand-craft them or reuse one across a different `orderBy`).
- **Optional live resolution:** when enabled, single-entity lookups fall back to on-chain reads via
  the ENSIP-10 Universal Resolver (with EIP-3668 CCIP-Read) and can verify ENSIP-3 primary names,
  so answers reflect live chain state on an indexed miss.
- Query depth/cost limits, request timeouts, a connection cap and per-IP rate limiting for DoS protection.
- **Optional MCP endpoint for AI agents:** `POST /mcp` speaks the Model Context Protocol, so agents
  (Claude, IDE assistants) can discover the API and query it — GraphQL taught via a tool primer plus
  per-type schema lookup, executing through the same hardened pipeline. Off by default (`MCP_ENABLED`).
- Conformant with the GraphQL-over-HTTP spec, while staying backward-compatible with legacy clients.

### Storage & operations
- Runs on **SQLite** (default) or **PostgreSQL** (managed/Neon via the `-Dpg-tls` build option).
- Webhooks: subscribe to event types and receive signed, automatically-retried HTTP deliveries
  (admin routes are authenticated by default — see [Configuration](#configuration)).
- Resumes from the last indexed block across restarts.
- Optional **finality signalling** — track the chain's safe/finalized blocks and expose how far the
  indexed head trails them.
- Optional Prometheus metrics (including chain-finality gauges) and a health/status endpoint.
- Docker images and Compose files for deployment.

## How it works

```
   ensv2-indexer / -v1 / -v2            ensv2-api
   ───────────────────────             ──────────
   RPC client ──► event decode         GraphQL HTTP server
        │           │                        │
        ▼           ▼                        ▼
   V1 / V2 event handlers             query → validate → resolve
        │                                    │
        └──────────────┬─────────────────────┘
                       ▼
                ┌──────────────┐
                │  SQLite /    │   (+ reorg-safe rollback,
                │  PostgreSQL  │      webhook delivery queue)
                └──────────────┘
```

The indexer pulls logs over JSON-RPC, decodes them, and writes derived ENS state to SQLite or
PostgreSQL. The API server reads from the same database. Chain reorgs are detected by block-hash
tracking and undone atomically.

## Build

Requires **Zig 0.16.0+** and an Ethereum/L2 JSON-RPC endpoint. (On macOS, prefix builds with
`PKG_CONFIG_PATH="/opt/homebrew/opt/sqlite/lib/pkgconfig:$PKG_CONFIG_PATH"` so SQLite links.)

```bash
git clone <repo-url> && cd zigens
zig build                 # build all binaries
zig build test            # run the test suite
zig build -Dpg-tls=true   # link OpenSSL for TLS Postgres (managed/Neon)
```

### Binaries

| Binary | Description |
|--------|-------------|
| `ensv2-indexer` | Combined V1 + V2 indexer (can also serve the API) |
| `ensv2-indexer-v1` / `-v2` | V1-only / V2-only indexer |
| `ensv2-api` | Standalone GraphQL API server (read-only) |
| `rainbow-backfill` | Resolve unknown `[0x…]` labels from the rainbow table |
| `test-db-reader` | Inspect / dump a database for debugging |

## Configuration

Set via a `.env` file (see [`.env.example`](.env.example) for the full list). Common options:

| Variable | Description | Default |
|----------|-------------|---------|
| `RPC_URL` | Ethereum / L2 JSON-RPC endpoint | `http://localhost:8545` |
| `NETWORK` | `sepolia` or `mainnet` | `sepolia` |
| `DATABASE_PATH` | SQLite database path | `./data/ens.db` |
| `DATABASE_BACKEND` / `DATABASE_URL` | `sqlite` (default) or `postgres`; a `postgres://` URL infers the backend | `sqlite` |
| `DATABASE_POOL_SIZE` | Postgres connection pool size | `10` |
| `START_BLOCK` | First block to index | contract deployment block |
| `API_PORT` | GraphQL API port | `8080` |
| `MANIFEST_PATH` | Contract-manifest `.zon` file (overrides built-in wiring) | built-in |
| `GRAPHQL_MAX_DEPTH` / `GRAPHQL_MAX_COST` | Query DoS limits | `10` / `10000` |
| `RATE_LIMIT_PER_SECOND` | RPC rate + API per-IP cap | `15` |
| `TRUSTED_PROXY_HOPS` | Trusted `X-Forwarded-For` hops for client-IP rate limiting (0 = don't trust XFF) | `0` |
| `REQUEST_TIMEOUT_MS` / `MAX_CONCURRENT_CONNECTIONS` | Slow-loris + connection-flood governors (timeout 0 disables) | `10000` / `512` |
| `WEBHOOKS_ENABLED` | Enable the webhook system | `false` |
| `WEBHOOK_ADMIN_USERNAME` / `WEBHOOK_ADMIN_PASSWORD` | Credentials for the webhook admin API (see below) | _unset_ |
| `WEBHOOKS_ALLOW_UNAUTHENTICATED` | Allow the webhook admin API with no credentials (local dev) | `false` |
| `FINALITY_ENABLED` | Track chain safe/finalized blocks + expose finality | `false` |
| `RESOLVE_LIVE_ENABLED` / `RESOLVE_CCIP_ENABLED` | Opt-in live on-chain resolution / CCIP-Read (CCIP requires live) | `false` |
| `MCP_ENABLED` | MCP agent endpoint at `POST /mcp` (read-only, same limits as GraphQL) | `false` |
| `PRIMARY_VERIFY_ENABLED` | ENSIP-3 primary-name verification field + `/internal/verify-primary` | `false` |

**Authentication is fail-closed.** The webhook admin API (`/api/webhooks/*`) requires
`WEBHOOK_ADMIN_USERNAME` + `WEBHOOK_ADMIN_PASSWORD` (or a bearer `INTERNAL_ADMIN_TOKEN`); set
`WEBHOOKS_ALLOW_UNAUTHENTICATED=true` to keep it open for local dev. The API also **refuses to
start** if only one of the webhook username/password is set (`PartialWebhookAdminConfig`), or if
`RESOLVE_CCIP_ENABLED` is set without `RESOLVE_LIVE_ENABLED` (`CcipRequiresLive`).

## Usage

```bash
# Index (resumes from the last synced block, then follows the chain head)
./zig-out/bin/ensv2-indexer

# Serve the GraphQL API (read-only)
./zig-out/bin/ensv2-api          # http://localhost:8080/graphql
```

`GET /graphql` opens the GraphiQL playground; `POST /graphql` runs queries. List queries return
**normalized, reachable** names by default — pass `includeUnnormalized: true` to include the rest.

### GraphQL examples

```graphql
# Domain with resolver records and subdomains.
# Note: `owner`/`registrant` are Account objects; `texts` returns record KEYS only —
# use `text(key: "...")` for a value.
query {
  domain(id: "tanrikulu.eth") {
    name expiryDate
    owner { id }
    resolver {
      address
      texts
      text(key: "avatar")
      addresses { coinTypeBig address }
    }
    subdomains { name }
  }
}

# Boolean filter: owner = X AND (name contains "dao" OR expiring before a date)
query {
  domains(where: {
    owner: "0x1111111111111111111111111111111111111111",
    or: [{ name_contains: "dao" }, { expiryDate_lt: 1767225600 }]
  }, first: 20) { name expiryDate }
}

# Cursor pagination (page 1; for the next page pass `after: <endCursor>` from pageInfo)
query {
  domainConnection(first: 10) {
    edges { node { name owner { id } } cursor }
    pageInfo { hasNextPage endCursor }
  }
}

# Indexing health and chain-finality lag (finality requires FINALITY_ENABLED)
query {
  _meta { block { number hash } hasIndexingErrors }
  _finality { head { number } safe { number } finalized { number } isStale }
}
```

### Webhooks

Enable with `WEBHOOKS_ENABLED=true`. The admin API is authenticated by default, so register with
credentials (or set `WEBHOOKS_ALLOW_UNAUTHENTICATED=true` for local dev):

```bash
curl -X POST http://localhost:8080/api/webhooks \
  -u "$WEBHOOK_ADMIN_USERNAME:$WEBHOOK_ADMIN_PASSWORD" \
  -H 'content-type: application/json' \
  -d '{"url":"https://example.com/hook","event_types":["NameRegistered","Transfer"]}'
```

Deliveries are signed JSON POSTs (verify `X-Webhook-Signature` =
`HMAC-SHA256(secret, "{X-Webhook-Timestamp}.{body}")`) and carry an `X-Webhook-Id` for idempotency.

## Project structure

```
zigens/
├── src/
│   ├── indexer/   # event indexing (abi, V1/V2 handlers, discovery)
│   ├── rpc/       # JSON-RPC client (batching, multi-address log queries)
│   ├── storage/   # SQLite layer (names, resolvers, events, sync, reorg undo-log)
│   ├── api/       # GraphQL server, handler, resolvers
│   ├── lib/graphql/  # GraphQL parser, executor, complexity, pagination
│   ├── webhooks/  # signed async delivery
│   ├── rainbow/   # labelhash → label lookup
│   ├── types/ utils/  # core types, ENSIP-15 normalization, helpers
│   └── *_main.zig # indexer / API entry points
├── schema.graphql       # GraphQL schema (source of truth)
├── schema/              # SQLite schema
├── tools/conformance/   # GraphQL spec conformance checks
└── Dockerfile, docker-compose*.yml
```

## Testing & conformance

```bash
zig build test                    # full suite (storage, GraphQL, indexer, integration, …)
cd tools/conformance && npm install
node schemacheck.mjs              # schema vs the graphql-js reference
node audit.mjs http://localhost:8080/graphql   # GraphQL-over-HTTP transport audit
```

## Notes

The API is **read-only** (no GraphQL mutations or subscriptions). The GraphQL **transport** is spec
conformant and the schema validates against the `graphql-js` reference; the execution engine
implements the subset of the GraphQL language spec that ENS clients use. Storage is SQLite or
PostgreSQL; reorg rollback covers a 1000-block window.

## License

MIT — see [LICENSE](LICENSE). ENS and ENS v2 design by ENS Labs; built with [Zig](https://ziglang.org/).
