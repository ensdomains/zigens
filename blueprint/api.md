# API

## GraphQL

`POST /graphql` — the primary surface. `GET /graphql` serves an interactive
playground in the browser; `GET /graphql?query=…` executes directly
(GraphQL-over-HTTP).

The schema is **ENS-subgraph-compatible**: queries written for the subgraph
work unchanged, guarded by a byte-for-byte golden conformance suite in CI.

```graphql
{
  domain(id: "vitalik.eth") {            # accepts a name or a namehash
    id name owner { id }
    resolver { addr texts }
    expiryDate isWrapped
  }
}
```

```graphql
{
  domains(where: { name_ends_with: "alice.eth" },
          orderBy: createdAt, orderDirection: desc, first: 10) {
    id name createdAt
  }
}
```

Relay-style pagination with stable cursors (cursors bind to their filter set —
changing the filter safely restarts the page):

```graphql
{
  domainConnection(first: 50, orderBy: createdAt, orderDirection: asc) {
    edges { cursor node { id name } }
    pageInfo { hasNextPage endCursor }
  }
}
```

### Extensions beyond the subgraph

| Field | What it adds |
|---|---|
| `Domain.protocol` | Which protocol a row came from (`v1` / `v2`) |
| `Domain.finality` | `FINALIZED` / `SAFE` / `HEAD` — how settled this row is |
| `_finality` | Chain safe/finalized positions + a conservative `isStale` |
| `_coverage` | What this deployment indexes: chain id, per-protocol head, freshness |
| `roles`, `registries`, … | ENS V2 permission and registry surfaces |

All extensions are additive — the subgraph-shaped fields never change meaning.

### Limits

Queries are validated against the schema and bounded by depth and cost budgets
(`GRAPHQL_MAX_DEPTH`, `GRAPHQL_MAX_COST`); requests are rate-limited per IP and
subject to a wall-clock timeout. Depth/cost violations return structured
GraphQL errors, rate limiting returns HTTP 429, and the timeout closes the
connection — never a hang.

## REST

| Endpoint | Purpose | Auth |
|---|---|---|
| `GET /health` | Liveness — process is up, never touches the DB | — |
| `GET /ready` | Readiness — 503 when the DB is unreachable | — |
| `GET /coverage` | What this deployment indexes (chain, heads, freshness) | — |
| `GET /metrics` | Prometheus metrics | — |
| `GET /api/name/{name}` | Single-name lookup | — |
| `GET /profiles/{name}` | Aggregated profile: core fields + resolver records + owner's primary name | — |
| `GET /api/owner/{address}` | Names owned by an address | — |
| `GET /api/events` | Recent indexed events | — |
| `GET /internal/verify-primary/{address}` | On-chain primary-name verification (needs `PRIMARY_VERIFY_ENABLED`) | admin |
| `GET /internal/explain/{name}` | Step-by-step trace of a live resolution (needs `RESOLVE_LIVE_ENABLED`) | admin |
| `GET /webhooks` | Webhook admin UI | admin |
| `/api/webhooks` | Webhook CRUD API | admin |

The probe endpoints also answer under `/api/…` aliases. "Admin" accepts either
`Bearer INTERNAL_ADMIN_TOKEN` or basic auth with
`WEBHOOK_ADMIN_USERNAME`/`PASSWORD`, and is fail-closed: with no credentials
configured the surface is disabled, not open (the webhook routes alone have an
explicit dev opt-out, `WEBHOOKS_ALLOW_UNAUTHENTICATED=true`).

## Webhooks

Register a URL and event types; deliveries are HMAC-SHA256-signed —
`X-Webhook-Signature: sha256=<hex>` over `{timestamp}.{payload}` with the
timestamp in `X-Webhook-Timestamp` — retried with backoff, and carry a stable
`X-Webhook-Id` for deduplication.

## MCP (agents)

`POST /mcp` — the same data over the
[Model Context Protocol](https://modelcontextprotocol.io), so AI agents
(Claude, IDE assistants, anything MCP-capable) discover and query ENSv2
without custom integration. **Off by default**; enable with `MCP_ENABLED=1`
(see [Deployment](deployment.md)).

Stateless Streamable HTTP: plain JSON-RPC over POST, no sessions, no SSE.
Read-only by construction — the `graphql-query` tool executes through the
same pipeline as `/graphql`, so cost limits, per-IP rate limiting and live
resolution behave identically on both surfaces.

| Tool / resource | What it does |
|---|---|
| `graphql-query` tool | Runs any GraphQL query; its description teaches agents the entry points, filter conventions and pitfalls, and errors carry line/column locations for self-correction |
| `get-graphql-schema` tool | Compact type index, or one type's full SDL on demand |
| `resolve-name` tool | One-call name resolution (address, resolver, chosen text records) over the live-capable single-name path |
| `examples` resource | Known-good queries with intents, mirrored from the conformance suite |
| `coverage` resource | Live indexing coverage / freshness snapshot |
