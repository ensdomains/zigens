# ENS Indexer (zigens)

A high-performance indexer for the Ethereum Name Service — **both ENS V1 (legacy) and ENS V2** —
written in Zig on SQLite, with a subgraph-compatible GraphQL API.

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
- Rich filtering, including `and` / `or` boolean conditions.
- Both offset (`first`/`skip`) and Relay cursor pagination.
- Query depth/cost limits and per-IP rate limiting for DoS protection.
- Conformant with the GraphQL-over-HTTP spec, while staying backward-compatible with legacy clients.

### Webhooks & operations
- Subscribe to event types and receive signed, automatically-retried HTTP deliveries.
- Resumes from the last indexed block across restarts.
- Optional Prometheus metrics and a health/status endpoint.
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
                │    SQLite    │   (+ reorg-safe rollback,
                │   database   │      webhook delivery queue)
                └──────────────┘
```

The indexer pulls logs over JSON-RPC, decodes them, and writes derived ENS state to SQLite. The API
server reads from the same database. Chain reorgs are detected by block-hash tracking and undone
atomically. See [`docs/`](docs/) for design notes (reorg handling, GraphQL conformance, V1 audit, …).

## Build

Requires **Zig 0.15.2+** and an Ethereum/L2 JSON-RPC endpoint. (On macOS, prefix builds with
`PKG_CONFIG_PATH="/opt/homebrew/opt/sqlite/lib/pkgconfig:$PKG_CONFIG_PATH"` so SQLite links.)

```bash
git clone <repo-url> && cd zigens
zig build          # build all binaries
zig build test     # run the test suite
```

### Binaries

| Binary | Description |
|--------|-------------|
| `ensv2-indexer` | Combined V1 + V2 indexer (can also serve the API) |
| `ensv2-indexer-v1` / `-v2` | V1-only / V2-only indexer |
| `ensv2-api` | Standalone GraphQL API server (read-only) |
| `rainbow-backfill` | Resolve unknown `[0x…]` labels from the rainbow table |

## Configuration

Set via a `.env` file (see [`.env.example`](.env.example) for the full list). Common options:

| Variable | Description | Default |
|----------|-------------|---------|
| `RPC_URL` | Ethereum / L2 JSON-RPC endpoint | `http://localhost:8545` |
| `NETWORK` | `sepolia` or `mainnet` | `sepolia` |
| `DATABASE_PATH` | SQLite database path | `./data/ens.db` |
| `START_BLOCK` | First block to index | contract deployment block |
| `API_PORT` | GraphQL API port | `8080` |
| `GRAPHQL_MAX_DEPTH` / `GRAPHQL_MAX_COST` | Query DoS limits | `10` / `10000` |
| `RATE_LIMIT_PER_SECOND` | RPC rate + API per-IP cap | `15` |
| `WEBHOOKS_ENABLED` | Enable the webhook system | `false` |

## Usage

```bash
# Index (resumes from the last synced block, then follows the chain head)
./zig-out/bin/ensv2-indexer

# Serve the GraphQL API (read-only)
./zig-out/bin/ensv2-api          # http://localhost:8080/graphql
```

`GET /graphql` opens the GraphiQL playground; `POST /graphql` runs queries.

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

# Indexing health
query { _meta { block { number hash } hasIndexingErrors } }
```

### Webhooks

Enable with `WEBHOOKS_ENABLED=true`, then register an endpoint:

```bash
curl -X POST http://localhost:8080/api/webhooks \
  -H 'content-type: application/json' \
  -d '{"url":"https://example.com/hook","event_types":["NameRegistered","Transfer"]}'
```

Deliveries are signed JSON POSTs (verify `X-Webhook-Signature` =
`HMAC-SHA256(secret, "{X-Webhook-Timestamp}.{body}")`).

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
├── docs/                # design & audit notes
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
implements the subset of the GraphQL language spec that ENS clients use. Storage is SQLite; reorg
rollback covers a 1000-block window.

## License

MIT — see [LICENSE](LICENSE). ENS and ENS v2 design by ENS Labs; built with [Zig](https://ziglang.org/).
