-- ENSv2 Indexer Database Schema
-- Initial schema for core ENS indexing functionality

-- ============================================================================
-- SYNC STATE
-- ============================================================================

CREATE TABLE IF NOT EXISTS sync_state (
  chain TEXT PRIMARY KEY,
  last_synced_block INTEGER NOT NULL,
  last_synced_at INTEGER NOT NULL
);

-- Block hashes for reorg detection
CREATE TABLE IF NOT EXISTS block_hashes (
  chain TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  block_hash TEXT NOT NULL,
  parent_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  PRIMARY KEY (chain, block_number)
);

CREATE INDEX IF NOT EXISTS idx_block_hashes_timestamp ON block_hashes(timestamp);

-- ============================================================================
-- REGISTRIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS registries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  address TEXT NOT NULL,
  name TEXT NOT NULL,
  namehash TEXT NOT NULL,
  parent_registry TEXT NOT NULL,
  created_block INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(chain, address)
);

CREATE INDEX IF NOT EXISTS idx_registries_chain ON registries(chain);
CREATE INDEX IF NOT EXISTS idx_registries_namehash ON registries(namehash);

-- ============================================================================
-- NAMES
-- ============================================================================

CREATE TABLE IF NOT EXISTS names (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
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
  ejected INTEGER NOT NULL DEFAULT 0,
  created_block INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_block INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(chain, namehash)
);

CREATE INDEX IF NOT EXISTS idx_names_chain ON names(chain);
CREATE INDEX IF NOT EXISTS idx_names_name ON names(name);
CREATE INDEX IF NOT EXISTS idx_names_label ON names(label);
CREATE INDEX IF NOT EXISTS idx_names_owner ON names(owner);
CREATE INDEX IF NOT EXISTS idx_names_token_id ON names(token_id);
CREATE INDEX IF NOT EXISTS idx_names_canonical_id ON names(canonical_id);
CREATE INDEX IF NOT EXISTS idx_names_expiry ON names(expiry);
CREATE INDEX IF NOT EXISTS idx_names_registry ON names(chain, registry);
CREATE INDEX IF NOT EXISTS idx_names_resolver ON names(chain, resolver);
CREATE INDEX IF NOT EXISTS idx_names_created_block ON names(chain, created_block);

-- ============================================================================
-- RESOLVERS
-- ============================================================================

CREATE TABLE IF NOT EXISTS resolvers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  address TEXT NOT NULL,
  name TEXT NOT NULL,
  namehash TEXT NOT NULL,
  set_block INTEGER NOT NULL,
  set_at INTEGER NOT NULL,
  UNIQUE(chain, namehash, address)
);

CREATE INDEX IF NOT EXISTS idx_resolvers_chain ON resolvers(chain);
CREATE INDEX IF NOT EXISTS idx_resolvers_namehash ON resolvers(namehash);

-- ============================================================================
-- RESOLVER DATA
-- ============================================================================

CREATE TABLE IF NOT EXISTS resolver_addresses (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  coin_type INTEGER NOT NULL,
  address TEXT NOT NULL,
  chain TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(namehash, coin_type)
);

CREATE INDEX IF NOT EXISTS idx_resolver_addresses_namehash ON resolver_addresses(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_addresses_resolver ON resolver_addresses(resolver);

CREATE TABLE IF NOT EXISTS resolver_contenthashes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL UNIQUE,
  resolver TEXT NOT NULL,
  contenthash TEXT NOT NULL,
  chain TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_namehash ON resolver_contenthashes(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_resolver ON resolver_contenthashes(resolver);

CREATE TABLE IF NOT EXISTS resolver_texts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  chain TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(namehash, key)
);

CREATE INDEX IF NOT EXISTS idx_resolver_texts_namehash ON resolver_texts(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_texts_resolver ON resolver_texts(resolver);
CREATE INDEX IF NOT EXISTS idx_resolver_texts_key ON resolver_texts(key);

-- ============================================================================
-- EVENTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  event_type TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  contract_address TEXT NOT NULL,
  name TEXT,
  namehash TEXT,
  data TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(chain, tx_hash, log_index)
);

CREATE INDEX IF NOT EXISTS idx_events_chain ON events(chain);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_block ON events(block_number);
CREATE INDEX IF NOT EXISTS idx_events_name ON events(name);
CREATE INDEX IF NOT EXISTS idx_events_namehash ON events(namehash);

-- ============================================================================
-- APPROVALS
-- ============================================================================

CREATE TABLE IF NOT EXISTS approvals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  token_id TEXT NOT NULL,
  owner TEXT NOT NULL,
  approved TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  tx_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(chain, token_id)
);

CREATE INDEX IF NOT EXISTS idx_approvals_chain ON approvals(chain);
CREATE INDEX IF NOT EXISTS idx_approvals_token_id ON approvals(token_id);
CREATE INDEX IF NOT EXISTS idx_approvals_owner ON approvals(owner);

-- ============================================================================
-- WEBHOOKS (MOVED TO SEPARATE DATABASE)
-- ============================================================================
-- Webhook tables have been moved to schema/webhooks/001_webhooks.sql
-- They now use a separate SQLite database (./data/webhooks.db) for better
-- thread isolation and to prevent database lock contention between the
-- main indexer and webhook worker threads.

-- ============================================================================
-- PERFORMANCE CACHES
-- ============================================================================

CREATE TABLE IF NOT EXISTS known_subregistries (
  chain TEXT NOT NULL,
  address TEXT NOT NULL,
  first_seen_block INTEGER NOT NULL,
  last_indexed_block INTEGER NOT NULL,
  PRIMARY KEY (chain, address)
);

CREATE INDEX IF NOT EXISTS idx_known_subregistries_last_indexed ON known_subregistries(chain, last_indexed_block);

CREATE TABLE IF NOT EXISTS known_resolvers (
  chain TEXT NOT NULL,
  address TEXT NOT NULL,
  first_seen_block INTEGER NOT NULL,
  last_indexed_block INTEGER NOT NULL,
  PRIMARY KEY (chain, address)
);

CREATE INDEX IF NOT EXISTS idx_known_resolvers_last_indexed ON known_resolvers(chain, last_indexed_block);
