-- ============================================================================
-- ENSv2 Indexer — Consolidated Database Schema
-- ============================================================================
--
-- Single source of truth. This file replaces the previous 27 numbered
-- migration files (001_initial.sql … 027_registration_economics.sql) that
-- evolved the schema incrementally.
--
-- POLICY: Re-indexing is required for any schema change. There are no
-- in-place ALTER TABLE migrations and no `migrate()` step in code. To pick
-- up a schema change, drop the database file and re-run the indexer; this
-- matches the indexer's recovery story for any structural fix and avoids
-- the bug surface of dual-path table definitions.
--
-- Notes on what was *not* carried forward from the numbered files:
--   * 008_temporary_registrar.sql: temp_auctions / temp_bids /
--     temp_bid_reveals / temp_invalidations — the handlers were deleted
--     (audit finding #8) and no client consumed them. DROPPED entirely.
--   * 009_temp_registrar_backfill.sql: the backfill INSERT was removed.
--     temp_pre_migration_names is still populated by handleV1NewOwner.
--   * 025_drop_redundant_v2_nameregistered.sql: the post-fix handler can't
--     produce the duplicate row this DELETE cleaned up. DROPPED.
--   * 002_bridge_events.sql comments referred to historical tables
--     (`migrations`, `renewal_syncs`) — those were already deleted in
--     2026-04 and are not part of the consolidated schema.
-- ============================================================================


-- ============================================================================
-- SYNC STATE & REORG TRACKING
-- ============================================================================

CREATE TABLE IF NOT EXISTS sync_state (
  protocol TEXT PRIMARY KEY,
  last_synced_block INTEGER NOT NULL,
  last_synced_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS block_hashes (
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  block_hash TEXT NOT NULL,
  parent_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  PRIMARY KEY (protocol, block_number)
);

CREATE INDEX IF NOT EXISTS idx_block_hashes_timestamp ON block_hashes(timestamp);


-- ============================================================================
-- ACCOUNTS
-- ============================================================================
-- First-class Account entity (subgraph parity). One row per address ever
-- observed as a domain owner, registrant, role grantee, transfer recipient,
-- or operator. Populated by an `upsertAccount` call from every event handler
-- that first observes an address in any of those roles. Backfilled once from
-- existing `names.owner`, `registrations.registrant`, and related columns.
--
-- Per-protocol isolation: `seen_v1` and `seen_v2` are independent 0/1 flags
-- (both can be 1 once the same address has been observed under each protocol).
-- This avoids the "first protocol wins" ambiguity of a single first_seen_protocol
-- column and lets queries answer "which addresses are V2-active" cleanly.
-- `first_seen_block` / `first_seen_timestamp` record the earlier of the two
-- observations.

CREATE TABLE IF NOT EXISTS accounts (
  address TEXT PRIMARY KEY,
  seen_v1 INTEGER NOT NULL DEFAULT 0,
  seen_v2 INTEGER NOT NULL DEFAULT 0,
  first_seen_block INTEGER NOT NULL,
  first_seen_timestamp INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_accounts_seen_v1 ON accounts(seen_v1) WHERE seen_v1 = 1;
CREATE INDEX IF NOT EXISTS idx_accounts_seen_v2 ON accounts(seen_v2) WHERE seen_v2 = 1;


-- ============================================================================
-- REGISTRIES
-- ============================================================================
-- UNIQUE(protocol, address, namehash) — the namehash component was added in
-- migration 015 to allow the same subregistry contract address to back
-- multiple parent names (e.g., shared subregistry contracts).

CREATE TABLE IF NOT EXISTS registries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  address TEXT NOT NULL,
  name TEXT NOT NULL,
  namehash TEXT NOT NULL,
  parent_registry TEXT NOT NULL,
  created_block INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(protocol, address, namehash)
);

CREATE INDEX IF NOT EXISTS idx_registries_protocol ON registries(protocol);
CREATE INDEX IF NOT EXISTS idx_registries_namehash ON registries(namehash);
CREATE INDEX IF NOT EXISTS idx_registries_address_block ON registries(protocol, address, created_block DESC);


-- ============================================================================
-- NAMES
-- ============================================================================
-- Folds in: 001 (base), 005 (wrapper + v1 cols), 012 (registrant),
-- 017 (registered_at), 026 (reachability cols).

CREATE TABLE IF NOT EXISTS names (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  name TEXT NOT NULL,
  namehash TEXT NOT NULL,
  label TEXT NOT NULL,
  label_hash TEXT NOT NULL,
  parent_name TEXT NOT NULL,
  parent_namehash TEXT NOT NULL,
  registry TEXT NOT NULL,
  owner TEXT NOT NULL,
  resolver TEXT,
  token_id TEXT NOT NULL,
  canonical_id TEXT NOT NULL,
  token_version INTEGER NOT NULL,
  expiry INTEGER,
  registry_locked INTEGER NOT NULL DEFAULT 0,
  migrated INTEGER NOT NULL DEFAULT 0,
  created_block INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_block INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  -- V1 / wrapper fields (migration 005)
  is_wrapped INTEGER NOT NULL DEFAULT 0,
  wrapper_fuses TEXT DEFAULT NULL,
  wrapper_expiry INTEGER DEFAULT NULL,
  is_v1_name INTEGER NOT NULL DEFAULT 0,
  v1_label_hash TEXT DEFAULT NULL,
  -- Registrant (migration 012); separate from owner (which can move via transfer)
  registrant TEXT,
  -- First-seen timestamp distinct from row creation (migration 017)
  registered_at INTEGER,
  -- Reachability (migration 026): soft delete on subregistry repoint
  is_reachable INTEGER NOT NULL DEFAULT 1,
  unreachable_since INTEGER,
  -- V1 ENS Registry TTL (NewTTL event). Null when unset.
  ttl INTEGER,
  -- V1 ENS Registry provenance: 1 when the row's most recent update came
  -- from the legacy pre-2020 Registry (0x314159…), 0 otherwise (new Registry
  -- 0x00…2e1e or V2). Mirrors subgraph's `isMigrated` (we keep our existing
  -- `migrated` column for the V1→V2 transition — a different concept).
  is_legacy INTEGER NOT NULL DEFAULT 0,
  -- V1-only materialized `resolvedAddress` (subgraph parity): the ETH address
  -- the resolver returns from `addr(node)` at NewResolver time. Lowercase hex
  -- string ("0x" + 40 hex) or NULL when unset / never materialized. V2 does
  -- not write this column — V2 readers fall back to the query-time resolver
  -- lookup (see api/builders/impl.zig:domainResolvedAddressHandler).
  resolved_address TEXT DEFAULT NULL,
  -- ENSIP-15 normalization status of `name`, computed at ingest. 1 = normalized,
  -- 0 = non-normalized or unknown label. Default-filtered out of GraphQL listings
  -- unless includeUnnormalized is passed (mirrors is_reachable).
  is_normalized INTEGER NOT NULL DEFAULT 1,
  -- Grace-inclusive expiry (subgraph `Domain.expiryDate`): bare stored expiry
  -- plus the 90d (7776000s) registrar grace for UNWRAPPED V1 .eth 2LDs only
  -- (wrapped rows already store the grace-inclusive wrapper value). This is the
  -- single SQL source of the rule that backs the `expiryDate`/`expiryDate_*`
  -- filters and ordering; a STORED generated column keeps it sargable via
  -- idx_names_expiry_effective (the old inline CASE defeated idx_names_expiry).
  -- Mirrors ens_fields.effectiveDomainExpiry on the read/serialization side.
  -- The maxInt(i64)-7776000 upper bound stops a near-max expiry from overflowing
  -- the addition (PG BIGINT errors; SQLite would silently widen to REAL).
  expiry_effective INTEGER GENERATED ALWAYS AS (
    CASE WHEN protocol = 'v1' AND parent_name = 'eth' AND is_wrapped = 0
           AND expiry > 0 AND expiry <= 9223372036846999807
         THEN expiry + 7776000 ELSE expiry END
  ) STORED,
  UNIQUE(protocol, namehash)
);

CREATE INDEX IF NOT EXISTS idx_names_protocol ON names(protocol);
CREATE INDEX IF NOT EXISTS idx_names_name ON names(name);
CREATE INDEX IF NOT EXISTS idx_names_label ON names(label);
CREATE INDEX IF NOT EXISTS idx_names_owner ON names(owner);
CREATE INDEX IF NOT EXISTS idx_names_token_id ON names(token_id);
CREATE INDEX IF NOT EXISTS idx_names_canonical_id ON names(canonical_id);
-- getNameByTokenIdAndRegistry filters (canonical_id, registry); a popular label's
-- canonical_id appears in many registries, so the single-column index leaves a per-row
-- `registry` Filter (EXPLAIN confirmed). This compound index makes registry an Index
-- Cond. Kept through bulk sync (handler lookup), like idx_names_canonical_id.
CREATE INDEX IF NOT EXISTS idx_names_canonical_id_registry ON names(canonical_id, registry);
CREATE INDEX IF NOT EXISTS idx_names_expiry ON names(expiry);
CREATE INDEX IF NOT EXISTS idx_names_expiry_effective ON names(expiry_effective);
CREATE INDEX IF NOT EXISTS idx_names_registry ON names(protocol, registry);
CREATE INDEX IF NOT EXISTS idx_names_resolver ON names(protocol, resolver);
CREATE INDEX IF NOT EXISTS idx_names_created_block ON names(protocol, created_block);
CREATE INDEX IF NOT EXISTS idx_names_namehash ON names(namehash);
CREATE INDEX IF NOT EXISTS idx_names_is_wrapped ON names(is_wrapped);
CREATE INDEX IF NOT EXISTS idx_names_is_v1_name ON names(is_v1_name);
CREATE INDEX IF NOT EXISTS idx_names_v1_label_hash ON names(v1_label_hash);
CREATE INDEX IF NOT EXISTS idx_names_wrapper_expiry ON names(wrapper_expiry);
CREATE INDEX IF NOT EXISTS idx_names_registrant ON names(registrant);
CREATE INDEX IF NOT EXISTS idx_names_parent_namehash ON names(parent_namehash);
CREATE INDEX IF NOT EXISTS idx_names_is_reachable ON names(protocol, is_reachable);
CREATE INDEX IF NOT EXISTS idx_names_registry_reachable ON names(protocol, registry, is_reachable);
CREATE INDEX IF NOT EXISTS idx_names_is_normalized ON names(is_normalized);

-- Partial index targeting Domain.subdomainsCount / subdomainCount / hasDirectSubdomains
-- / getSubdomains queries (see src/storage/names.zig:SUBDOMAIN_GC_FILTER for the matching
-- WHERE clause). The WHERE predicate here MUST stay byte-identical to the query's
-- predicate; SQLite only uses a partial index when the query's WHERE is provably implied
-- by the index's WHERE. The constants `'0x0000…0000'` are literal 0x-prefixed lowercase
-- zero-addresses to match Address.toHexBuf output.
--
-- Subgraph clients persist a `subdomainCount` column and increment per-event. We use a
-- runtime SQL COUNT against this index instead because:
--   1. The V2 reachability cascade (`setRegistriesReachability`) bulk-flips many rows in
--      one UPDATE; per-event counter maintenance doesn't model bulk flips cleanly.
--   2. SQL COUNT against a partial index is fast enough (O(matching rows) per parent),
--      bounded by typical subdomain counts (0–10 for most names).
--   3. Zero counter-drift surface: correctness is structural, not coordination-dependent.
CREATE INDEX IF NOT EXISTS idx_names_subdomain_count
ON names(parent_name)
WHERE is_reachable = 1
  AND NOT (owner = '0x0000000000000000000000000000000000000000'
       AND resolver = '0x0000000000000000000000000000000000000000');


-- ============================================================================
-- REGISTRY ENTRIES (on-chain Entry mirror; migration 026)
-- ============================================================================
-- Mirrors PermissionedRegistry.Entry per (parent_registry, canonical_id) so
-- SubregistryUpdated can cascade-invalidate descendants on repoint.

CREATE TABLE IF NOT EXISTS registry_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  parent_registry TEXT NOT NULL,
  canonical_id TEXT NOT NULL,
  subregistry TEXT NOT NULL DEFAULT '0x0000000000000000000000000000000000000000',
  updated_block INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(protocol, parent_registry, canonical_id)
);

CREATE INDEX IF NOT EXISTS idx_registry_entries_subregistry ON registry_entries(protocol, subregistry);
CREATE INDEX IF NOT EXISTS idx_registry_entries_parent ON registry_entries(protocol, parent_registry);


-- ============================================================================
-- RESOLVERS
-- ============================================================================

CREATE TABLE IF NOT EXISTS resolvers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  address TEXT NOT NULL,
  name TEXT NOT NULL,
  namehash TEXT NOT NULL,
  set_block INTEGER NOT NULL,
  set_at INTEGER NOT NULL,
  UNIQUE(protocol, namehash, address)
);

CREATE INDEX IF NOT EXISTS idx_resolvers_protocol ON resolvers(protocol);
CREATE INDEX IF NOT EXISTS idx_resolvers_namehash ON resolvers(namehash);


-- ============================================================================
-- RESOLVER RECORDS (addresses / contenthashes / texts)
-- ============================================================================
-- Final UNIQUE(protocol, resolver, namehash, …) shapes from migration 022.
-- The (resolver-scoped) constraint prevents V2 writes from REPLACE-ing V1
-- rows for migrated names.

CREATE TABLE IF NOT EXISTS resolver_addresses (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  coin_type INTEGER NOT NULL,
  address TEXT NOT NULL,
  context TEXT,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash, coin_type)
);

CREATE INDEX IF NOT EXISTS idx_resolver_addresses_namehash ON resolver_addresses(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_addresses_resolver ON resolver_addresses(resolver);
CREATE INDEX IF NOT EXISTS idx_resolver_addresses_context ON resolver_addresses(protocol, namehash, context);

CREATE TABLE IF NOT EXISTS resolver_contenthashes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  contenthash TEXT NOT NULL,
  context TEXT,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash)
);

CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_namehash ON resolver_contenthashes(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_resolver ON resolver_contenthashes(resolver);
CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_context ON resolver_contenthashes(protocol, namehash, context);

CREATE TABLE IF NOT EXISTS resolver_texts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  context TEXT,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash, key)
);

CREATE INDEX IF NOT EXISTS idx_resolver_texts_namehash ON resolver_texts(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_texts_resolver ON resolver_texts(resolver);
CREATE INDEX IF NOT EXISTS idx_resolver_texts_key ON resolver_texts(key);
CREATE INDEX IF NOT EXISTS idx_resolver_texts_context ON resolver_texts(protocol, namehash, context);


-- ============================================================================
-- RESOLVER RECORDS (OwnedResolver: aliases / pubkeys / abis / names / interfaces / versions)
-- ============================================================================
-- Migration 018 introduced these tables; migration 022 rescoped uniqueness
-- to include `resolver`. Aliases are NOT versioned (not cleared by
-- VersionChanged).

CREATE TABLE IF NOT EXISTS resolver_aliases (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  resolver TEXT NOT NULL,
  from_name TEXT NOT NULL,
  to_name TEXT NOT NULL,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(resolver, from_name)
);

CREATE INDEX IF NOT EXISTS idx_resolver_aliases_resolver ON resolver_aliases(resolver);

CREATE TABLE IF NOT EXISTS resolver_pubkeys (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  x TEXT NOT NULL,
  y TEXT NOT NULL,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash)
);

CREATE INDEX IF NOT EXISTS idx_resolver_pubkeys_namehash ON resolver_pubkeys(namehash);

CREATE TABLE IF NOT EXISTS resolver_abis (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  content_type INTEGER NOT NULL,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash, content_type)
);

CREATE INDEX IF NOT EXISTS idx_resolver_abis_namehash ON resolver_abis(namehash);

CREATE TABLE IF NOT EXISTS resolver_names (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  name TEXT NOT NULL,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash)
);

CREATE INDEX IF NOT EXISTS idx_resolver_names_namehash ON resolver_names(namehash);

CREATE TABLE IF NOT EXISTS resolver_interfaces (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  interface_id TEXT NOT NULL,
  implementer TEXT NOT NULL,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash, interface_id)
);

CREATE INDEX IF NOT EXISTS idx_resolver_interfaces_namehash ON resolver_interfaces(namehash);

CREATE TABLE IF NOT EXISTS resolver_authorisations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  owner TEXT NOT NULL,
  target TEXT NOT NULL,
  is_authorised INTEGER NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash, owner, target)
);

CREATE INDEX IF NOT EXISTS idx_resolver_authorisations_namehash ON resolver_authorisations(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_authorisations_owner ON resolver_authorisations(owner);

CREATE TABLE IF NOT EXISTS resolver_dns_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  dns_name TEXT NOT NULL,
  resource INTEGER NOT NULL,
  record TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash, dns_name, resource)
);

CREATE INDEX IF NOT EXISTS idx_resolver_dns_records_namehash ON resolver_dns_records(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_dns_records_resolver ON resolver_dns_records(resolver);

CREATE TABLE IF NOT EXISTS resolver_dns_zonehashes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  zonehash TEXT NOT NULL,
  last_zonehash TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash)
);

CREATE INDEX IF NOT EXISTS idx_resolver_dns_zonehashes_namehash ON resolver_dns_zonehashes(namehash);

CREATE TABLE IF NOT EXISTS resolver_versions (
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  version INTEGER NOT NULL,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  PRIMARY KEY (resolver, namehash)
);


-- ============================================================================
-- RESOLVER METADATA & APPROVALS (ENSIP-16 offchain; migration 004)
-- ============================================================================

CREATE TABLE IF NOT EXISTS resolver_metadata (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  resolver TEXT NOT NULL,
  graphql_url TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver)
);

CREATE INDEX IF NOT EXISTS idx_resolver_metadata_protocol ON resolver_metadata(protocol);
CREATE INDEX IF NOT EXISTS idx_resolver_metadata_resolver ON resolver_metadata(protocol, resolver);

CREATE TABLE IF NOT EXISTS resolver_approvals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  resolver TEXT NOT NULL,
  namehash TEXT NOT NULL,
  context TEXT,
  delegate TEXT NOT NULL,
  approved INTEGER NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, namehash, context, delegate)
);

CREATE INDEX IF NOT EXISTS idx_resolver_approvals_protocol ON resolver_approvals(protocol);
CREATE INDEX IF NOT EXISTS idx_resolver_approvals_namehash ON resolver_approvals(protocol, namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_approvals_delegate ON resolver_approvals(protocol, delegate);
CREATE INDEX IF NOT EXISTS idx_resolver_approvals_context ON resolver_approvals(protocol, context);

-- Resource-naming discovery (PermissionedResolver Named*Resource events): maps
-- an EAC resource id to the name/record it guards on a resolver. Emitted once,
-- on the first role grant for a resource. One row per (resolver, resource);
-- record_key/coin_type are attributes ('' / -1 when not applicable), so the
-- UNIQUE key has no nullable columns (SQL NULLs never conflict).
CREATE TABLE IF NOT EXISTS resolver_named_resources (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  resolver TEXT NOT NULL,
  resource TEXT NOT NULL,
  record_kind TEXT NOT NULL,
  record_key TEXT NOT NULL DEFAULT '',
  coin_type INTEGER NOT NULL DEFAULT -1,
  name TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver, resource)
);

CREATE INDEX IF NOT EXISTS idx_named_resources_resolver ON resolver_named_resources(protocol, resolver);


-- ============================================================================
-- EVENTS
-- ============================================================================
-- Indexes from 001 plus migration 013 (contract_address, protocol+type+block,
-- block+log_index) and migration 024 (expression index on data->owner).

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  event_type TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  contract_address TEXT NOT NULL,
  name TEXT,
  namehash TEXT,
  data TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, tx_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_events_protocol ON events(protocol);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_block ON events(block_number);
CREATE INDEX IF NOT EXISTS idx_events_name ON events(name);
CREATE INDEX IF NOT EXISTS idx_events_namehash ON events(namehash);
CREATE INDEX IF NOT EXISTS idx_events_contract_address ON events(contract_address);
CREATE INDEX IF NOT EXISTS idx_events_protocol_type_block ON events(protocol, event_type, block_number);
CREATE INDEX IF NOT EXISTS idx_events_block_log ON events(block_number, log_index);
CREATE INDEX IF NOT EXISTS idx_events_owner_extracted ON events (LOWER(json_extract(data, '$.owner')));


-- ============================================================================
-- APPROVALS
-- ============================================================================
-- Final UNIQUE(protocol, token_id, registry) from migration 020.

CREATE TABLE IF NOT EXISTS approvals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  token_id TEXT NOT NULL,
  owner TEXT NOT NULL,
  approved TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  registry TEXT NOT NULL DEFAULT '',
  UNIQUE(protocol, token_id, registry)
);

CREATE INDEX IF NOT EXISTS idx_approvals_protocol ON approvals(protocol);
CREATE INDEX IF NOT EXISTS idx_approvals_token_id ON approvals(token_id);
CREATE INDEX IF NOT EXISTS idx_approvals_owner ON approvals(owner);


-- ============================================================================
-- EAC ROLES (Enhanced Access Control role assignments)
-- ============================================================================
-- Final UNIQUE(protocol, resource, account, contract_address) from
-- migration 020 (registry-scoped).

CREATE TABLE IF NOT EXISTS eac_roles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  resource TEXT NOT NULL,
  account TEXT NOT NULL,
  role_bitmap TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  contract_address TEXT NOT NULL DEFAULT '',
  UNIQUE(protocol, resource, account, contract_address)
);

CREATE INDEX IF NOT EXISTS idx_eac_roles_protocol ON eac_roles(protocol);
CREATE INDEX IF NOT EXISTS idx_eac_roles_resource ON eac_roles(protocol, resource);
CREATE INDEX IF NOT EXISTS idx_eac_roles_account ON eac_roles(protocol, account);
CREATE INDEX IF NOT EXISTS idx_eac_roles_block ON eac_roles(protocol, block_number);
CREATE INDEX IF NOT EXISTS idx_eac_roles_contract ON eac_roles(protocol, contract_address);


-- ============================================================================
-- TOKEN OBSERVERS (V2 Registry TokenObserverSet event; migration 002)
-- ============================================================================

CREATE TABLE IF NOT EXISTS token_observers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  token_id TEXT NOT NULL,
  observer TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, transaction_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_token_observers_token_id ON token_observers(protocol, token_id);
CREATE INDEX IF NOT EXISTS idx_token_observers_block ON token_observers(protocol, block_number);
CREATE INDEX IF NOT EXISTS idx_token_observers_observer ON token_observers(observer);


-- ============================================================================
-- V1 LABELS (TokenID → label mapping for V1 Base Registrar; migration 005)
-- ============================================================================

CREATE TABLE IF NOT EXISTS v1_labels (
  token_id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  namehash TEXT NOT NULL,
  first_seen_block INTEGER NOT NULL,
  first_seen_tx TEXT NOT NULL,
  source TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_v1_labels_label ON v1_labels(label);
CREATE INDEX IF NOT EXISTS idx_v1_labels_namehash ON v1_labels(namehash);


-- ============================================================================
-- V1 CONTROLLERS (dynamic discovery; migration 006)
-- ============================================================================

CREATE TABLE IF NOT EXISTS v1_controllers (
    controller_address TEXT PRIMARY KEY,
    added_block_number INTEGER NOT NULL,
    removed_block_number INTEGER,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    added_tx_hash TEXT NOT NULL,
    removed_tx_hash TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_v1_controllers_active ON v1_controllers(is_active);
CREATE INDEX IF NOT EXISTS idx_v1_controllers_added_block ON v1_controllers(added_block_number);

-- Seed all known V1 ETH Registrar Controllers (migration 007). Required so the
-- indexer can pick them up regardless of the starting block.
INSERT OR IGNORE INTO v1_controllers (controller_address, added_block_number, is_active, added_tx_hash) VALUES
-- Controller 1: Added at V1 launch (May 2019)
('0x4fe4e666be5752f1fdd210f4ab5de2cc26e3e0e8', 9380422, 1, '0xeec39f7b60f177691601b4c4f90ea31d7f27344824abceda3f4417772d7b715e'),
-- Controller 2: Added shortly after launch
('0x60c7c2a24b5e86c38639fd1586917a8fef66a56d', 9380466, 1, '0xbd27ed3473911a633d4df33f0666674f0d02906e812d30b4a0d08f00a0f8ba04'),
-- Controller 3: Added day 1
('0xcf60916b6cb4753f58533808fa610fcbd4098ec0', 9381046, 1, '0x5c83b117a84e88341c70df551f8be393e2989a4f6ca0395f8089cc3a1e8439a1'),
-- Controller 4: Added ~1 week after launch
('0x6109dd117aa5486605fc85e040ab00163a75c662', 9411159, 1, '0x83e31c88aef44ba2ce964cec50141d7322d5c3e97c46ddf5dcc52cfdc53f9b0d'),
-- Controller 5: Added ~2 weeks after launch (May 2019)
('0x283af0b28c62c092c9727f1ee09c02ca627eb7f5', 9456489, 1, '0x4e1532fbb95ec440a816d3ff5e49280796a03117b703adbea82de0897850861f'),
-- Controller 6: Added ~2022-2023
('0xd4416b13d2b3a9abae7acd5d6c2bbdbe25686401', 16996231, 1, '0x47fc32e0e2882dac1691464e3aa93126f6963ca8ae651c30b7721555c3aedc6d'),
-- Controller 7: Added ~2025 (most recent)
('0x59e16fccd424cc24e280be16e11bcd56fb0ce547', 23044126, 1, '0xa4da70aac93eeee2be6c74d3c496451a07195e46127be573dd218886caef505a');


-- ============================================================================
-- NAME HISTORY (state-change audit log; migration 005)
-- ============================================================================

CREATE TABLE IF NOT EXISTS name_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  namehash TEXT NOT NULL,
  name TEXT NOT NULL,
  change_type TEXT NOT NULL,
  old_value TEXT,
  new_value TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, namehash, change_type, block_number, log_index)
);

CREATE INDEX IF NOT EXISTS idx_name_history_namehash ON name_history(namehash);
CREATE INDEX IF NOT EXISTS idx_name_history_protocol_name ON name_history(protocol, name);
CREATE INDEX IF NOT EXISTS idx_name_history_change_type ON name_history(change_type);
CREATE INDEX IF NOT EXISTS idx_name_history_block ON name_history(protocol, block_number);
CREATE INDEX IF NOT EXISTS idx_name_history_timestamp ON name_history(timestamp);


-- ============================================================================
-- TEMP PRE-MIGRATION NAMES (V1 NewOwner during temporary registrar era; migration 009)
-- ============================================================================
-- Populated by handleV1NewOwner; consumed by backfillPreMigrationNames.
-- The temp_auctions / temp_bids / temp_bid_reveals / temp_invalidations
-- tables that used to live alongside this one have been removed (their
-- handlers were deleted as part of the V1 audit cleanup).

CREATE TABLE IF NOT EXISTS temp_pre_migration_names (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  namehash TEXT NOT NULL,
  label_hash TEXT NOT NULL,
  parent_node TEXT NOT NULL,
  owner TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(protocol, namehash)
);

CREATE INDEX IF NOT EXISTS idx_temp_pre_migration_label_hash ON temp_pre_migration_names(label_hash);
CREATE INDEX IF NOT EXISTS idx_temp_pre_migration_protocol ON temp_pre_migration_names(protocol);

CREATE TABLE IF NOT EXISTS backfill_status (
  task TEXT PRIMARY KEY,
  completed INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER,
  records_processed INTEGER DEFAULT 0
);


-- ============================================================================
-- UNKNOWN LABELS (labelhash → label backfill queue; migration 010)
-- ============================================================================

CREATE TABLE IF NOT EXISTS unknown_labels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name_id INTEGER,
    transaction_hash TEXT NOT NULL,
    labelhash TEXT NOT NULL,
    namehash TEXT NOT NULL,
    parent_node TEXT NOT NULL,
    owner TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    backfill_attempts INTEGER NOT NULL DEFAULT 0,
    last_backfill_attempt INTEGER,
    FOREIGN KEY (name_id) REFERENCES names(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_unknown_labels_backfill
    ON unknown_labels(backfill_attempts, created_at)
    WHERE backfill_attempts < 3;
CREATE INDEX IF NOT EXISTS idx_unknown_labels_tx_hash ON unknown_labels(transaction_hash);
CREATE INDEX IF NOT EXISTS idx_unknown_labels_labelhash ON unknown_labels(labelhash);
CREATE UNIQUE INDEX IF NOT EXISTS idx_unknown_labels_unique ON unknown_labels(labelhash, parent_node);


-- ============================================================================
-- RAINBOW LABELS (labelhash → label cache; migration 011)
-- ============================================================================

CREATE TABLE IF NOT EXISTS rainbow_labels (
    labelhash TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('controller', 'calldata', 'wrapper', 'manual')),
    first_seen_block INTEGER NOT NULL,
    first_seen_tx TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_rainbow_source ON rainbow_labels(source);
CREATE INDEX IF NOT EXISTS idx_rainbow_block ON rainbow_labels(first_seen_block);

CREATE TABLE IF NOT EXISTS rainbow_stats (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

INSERT OR IGNORE INTO rainbow_stats (key, value) VALUES
    ('total_labels', '0'),
    ('controller_labels', '0'),
    ('calldata_labels', '0'),
    ('wrapper_labels', '0'),
    ('manual_labels', '0'),
    ('last_updated_block', '0');


-- ============================================================================
-- ORPHANED REGISTRATIONS (deferred NameRegistered queue; migration 016)
-- ============================================================================

CREATE TABLE IF NOT EXISTS orphaned_registrations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  subregistry_address TEXT NOT NULL,
  token_id TEXT NOT NULL,
  label TEXT NOT NULL,
  expiry INTEGER NOT NULL,
  owner TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(protocol, tx_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_orphaned_subregistry ON orphaned_registrations(protocol, subregistry_address);
CREATE INDEX IF NOT EXISTS idx_orphaned_block ON orphaned_registrations(block_number);


-- ============================================================================
-- REGISTRATIONS (first-class registrations table; migration 021 + 027 economics)
-- ============================================================================
-- Previously derived from `events` with JSON parsing. This dedicated table is
-- the canonical writer per (protocol, namehash). Economics columns (base_cost,
-- premium, label_name, referrer) come from the matching ETH Controller /
-- ETHRegistrar event that fires shortly after the base registration in the
-- same tx; updateRegistrationEconomics enriches the row.

CREATE TABLE IF NOT EXISTS registrations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  namehash TEXT NOT NULL,
  label TEXT NOT NULL,
  parent_name TEXT NOT NULL,
  registrant TEXT NOT NULL,
  registered_at INTEGER NOT NULL,
  expiry INTEGER,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  base_cost TEXT,
  premium TEXT,
  label_name TEXT,
  referrer TEXT,
  UNIQUE(protocol, transaction_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_registrations_protocol_registrant ON registrations(protocol, registrant);
CREATE INDEX IF NOT EXISTS idx_registrations_protocol_namehash ON registrations(protocol, namehash);
CREATE INDEX IF NOT EXISTS idx_registrations_protocol_registered_at ON registrations(protocol, registered_at);
CREATE INDEX IF NOT EXISTS idx_registrations_protocol_expiry ON registrations(protocol, expiry);


-- ============================================================================
-- REVERSE RECORDS (address → reverse namehash binding; migration 023)
-- ============================================================================

CREATE TABLE IF NOT EXISTS reverse_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  address TEXT NOT NULL,
  namehash TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, address)
);

CREATE INDEX IF NOT EXISTS idx_reverse_records_protocol_address ON reverse_records(protocol, address);
CREATE INDEX IF NOT EXISTS idx_reverse_records_namehash ON reverse_records(namehash);


-- ============================================================================
-- PERFORMANCE CACHES (subregistry / resolver discovery)
-- ============================================================================

CREATE TABLE IF NOT EXISTS known_subregistries (
  protocol TEXT NOT NULL,
  address TEXT NOT NULL,
  first_seen_block INTEGER NOT NULL,
  last_indexed_block INTEGER NOT NULL,
  PRIMARY KEY (protocol, address)
);

CREATE INDEX IF NOT EXISTS idx_known_subregistries_last_indexed ON known_subregistries(protocol, last_indexed_block);

CREATE TABLE IF NOT EXISTS known_resolvers (
  protocol TEXT NOT NULL,
  address TEXT NOT NULL,
  first_seen_block INTEGER NOT NULL,
  last_indexed_block INTEGER NOT NULL,
  PRIMARY KEY (protocol, address)
);

CREATE INDEX IF NOT EXISTS idx_known_resolvers_last_indexed ON known_resolvers(protocol, last_indexed_block);
