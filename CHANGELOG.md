# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-17

First versioned release.

### Indexing
- ENS V1 (legacy registry, base registrar, controllers, NameWrapper) and ENS V2
  (registries, ETH registrar, EAC permissions) event indexing on one process or
  as split per-protocol binaries.
- Fail-closed reorg handling: schema-driven undo-log capture with per-block
  (hash, parent-hash) lineage near the tip; rollback refuses to guess past its
  retention window.
- Rebuildable projections: `--backfill` reconstructs every projection table
  (names, resolver records, roles, registrations, accounts, registries) from
  the stored event log, byte-identical to live indexing, on both backends.
- Rainbow-table label healing with automatic download support.

### Storage
- Dual database backend: embedded SQLite (single-binary deployments) and
  PostgreSQL (including TLS for managed providers), with a generated,
  drift-checked Postgres schema.

### API
- Subgraph-compatible GraphQL endpoint with filter/order/pagination parity,
  Relay-style connections with filter-bound keyset cursors, and
  snapshot-consistent page counts; golden-file conformance gate in CI.
- Opt-in query-time resolution: ENSIP-10 Universal Resolver fallback,
  CCIP-Read (EIP-3668) with hardened gateway transport, and ENSIP-3
  primary-name forward verification.
- Finality signalling: safe/finalized tiers in `_finality`, per-domain
  finality annotation, and Prometheus metrics at `/metrics`.
- Operations surface: `/health` liveness, `/ready` readiness (503 on DB
  unavailability), per-IP rate limiting, request timeouts, connection caps,
  and constant-time authenticated admin endpoints.
- Webhooks with HMAC-signed deliveries, retry queue, and admin UI.

### Operations
- Graceful shutdown on SIGTERM/SIGINT for both binaries: the API drains
  in-flight connections; the indexer stops at a batch boundary with committed,
  resumable sync state. A second signal force-exits.
- Container image published to ghcr.io on version tags.
