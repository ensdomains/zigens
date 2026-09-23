# GraphQL conformance e2e

Two surfaces, two suites (see `docs/graphql-conformance.md` for the rationale):

| Surface | Suite | Needs a running server? |
|---|---|---|
| Schema / language / introspection | `graphql-js` (reference impl) | No |
| GraphQL-over-HTTP transport | `graphql-http` audit | Yes |

## 0. Install the JS deps (once)

```bash
cd tools/conformance
npm install            # graphql + graphql-http
# (only if you run the HTTP audit through a proxy:) npm install undici@6
```

## 1. Schema + introspection conformance (no server)

```bash
node schemacheck.mjs
# -> "SCHEMA: builds under the graphql-js reference parser/validator  OK"
#    + a field/type diff of src/api/introspection.json vs the canonical introspection.
# exit 0 = clean.
```

This is the one that already caught two real spec violations (a duplicate description and a
duplicate `AccountFilter` type). Run it after any `schema.graphql` edit.

## 2. HTTP transport audit (needs the server)

Build + start the API (a real filesystem has none of the sandbox's process/db flakiness):

```bash
# from the repo root
zig build                                   # macOS: PKG_CONFIG_PATH="/opt/homebrew/opt/sqlite/lib/pkgconfig:$PKG_CONFIG_PATH" zig build

# (optional) fresh ENSv2 index — otherwise point at your existing DATABASE_PATH:
rm -f data/ens.db data/ens.db-shm data/ens.db-wal
START_BLOCK=10893210 ./zig-out/bin/ensv2-indexer-v2          # Ctrl-C once it reaches the chain head

# serve it (use a throwaway webhook db so nothing else is touched):
WEBHOOKS_ENABLED=false ./zig-out/bin/ensv2-api &             # listens on API_PORT (default 8080)
```

Then run the audit + the negotiation probes (pass a different URL if you set a custom API_PORT):

```bash
cd tools/conformance
node audit.mjs http://localhost:8080/graphql                # graphql-http MUST/SHOULD report
./probe.sh    http://localhost:8080/graphql                 # legacy-vs-strict status/content-type
```

Expected on a current build: `error(MUST)=0, warn(SHOULD)=0`, with 12 optional `notice(MAY)` items —
those want a `400` on bad-typed params sent with **no `Accept` header** (the legacy `application/json`
path), which we intentionally keep lenient; the strict path returns `400` for them (see `probe.sh`).

`probe.sh` confirms the backward-compat guarantee directly:

- **legacy path** (default `Accept`) → `200 application/json` for valid, parse, and validation
  cases — unchanged for ensjs / subgraph / Apollo clients;
- **strict path** (`Accept: application/graphql-response+json`) → `200` on success,
  `400` on parse/validation/bad-params, with the `application/graphql-response+json` content-type.

You can also audit the live deployment directly: `node audit.mjs https://graphql.ens.dev/`.
