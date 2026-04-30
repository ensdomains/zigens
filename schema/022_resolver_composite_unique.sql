-- ENSv2 Indexer Database Schema
-- Migration 022: Resolver records scoped by (resolver, ...) for migration-safe uniqueness
-- Fixes data loss: prior UNIQUE(namehash, ...) caused V2 writes to REPLACE V1 rows
-- for migrated names. Existing DBs must re-index to recover lost V1 records.

-- ============================================================================
-- resolver_addresses: UNIQUE(namehash, coin_type) -> UNIQUE(protocol, resolver, namehash, coin_type)
-- ============================================================================
CREATE TABLE IF NOT EXISTS resolver_addresses_new (
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
INSERT OR IGNORE INTO resolver_addresses_new
  SELECT id, namehash, resolver, coin_type, address, context, protocol, block_number, transaction_hash, timestamp
  FROM resolver_addresses;
DROP TABLE resolver_addresses;
ALTER TABLE resolver_addresses_new RENAME TO resolver_addresses;
CREATE INDEX IF NOT EXISTS idx_resolver_addresses_namehash ON resolver_addresses(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_addresses_resolver ON resolver_addresses(resolver);
CREATE INDEX IF NOT EXISTS idx_resolver_addresses_context ON resolver_addresses(protocol, namehash, context);

-- ============================================================================
-- resolver_contenthashes: namehash UNIQUE -> UNIQUE(protocol, resolver, namehash)
-- ============================================================================
CREATE TABLE IF NOT EXISTS resolver_contenthashes_new (
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
INSERT OR IGNORE INTO resolver_contenthashes_new
  SELECT id, namehash, resolver, contenthash, context, protocol, block_number, transaction_hash, timestamp
  FROM resolver_contenthashes;
DROP TABLE resolver_contenthashes;
ALTER TABLE resolver_contenthashes_new RENAME TO resolver_contenthashes;
CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_namehash ON resolver_contenthashes(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_resolver ON resolver_contenthashes(resolver);
CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_context ON resolver_contenthashes(protocol, namehash, context);

-- ============================================================================
-- resolver_texts: UNIQUE(namehash, key) -> UNIQUE(protocol, resolver, namehash, key)
-- ============================================================================
CREATE TABLE IF NOT EXISTS resolver_texts_new (
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
INSERT OR IGNORE INTO resolver_texts_new
  SELECT id, namehash, resolver, key, value, context, protocol, block_number, transaction_hash, timestamp
  FROM resolver_texts;
DROP TABLE resolver_texts;
ALTER TABLE resolver_texts_new RENAME TO resolver_texts;
CREATE INDEX IF NOT EXISTS idx_resolver_texts_namehash ON resolver_texts(namehash);
CREATE INDEX IF NOT EXISTS idx_resolver_texts_resolver ON resolver_texts(resolver);
CREATE INDEX IF NOT EXISTS idx_resolver_texts_key ON resolver_texts(key);
CREATE INDEX IF NOT EXISTS idx_resolver_texts_context ON resolver_texts(protocol, namehash, context);

-- ============================================================================
-- resolver_pubkeys: namehash UNIQUE -> UNIQUE(protocol, resolver, namehash)
-- ============================================================================
CREATE TABLE IF NOT EXISTS resolver_pubkeys_new (
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
INSERT OR IGNORE INTO resolver_pubkeys_new
  SELECT id, namehash, resolver, x, y, protocol, block_number, transaction_hash, timestamp
  FROM resolver_pubkeys;
DROP TABLE resolver_pubkeys;
ALTER TABLE resolver_pubkeys_new RENAME TO resolver_pubkeys;
CREATE INDEX IF NOT EXISTS idx_resolver_pubkeys_namehash ON resolver_pubkeys(namehash);

-- ============================================================================
-- resolver_abis: UNIQUE(namehash, content_type) -> UNIQUE(protocol, resolver, namehash, content_type)
-- ============================================================================
CREATE TABLE IF NOT EXISTS resolver_abis_new (
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
INSERT OR IGNORE INTO resolver_abis_new
  SELECT id, namehash, resolver, content_type, protocol, block_number, transaction_hash, timestamp
  FROM resolver_abis;
DROP TABLE resolver_abis;
ALTER TABLE resolver_abis_new RENAME TO resolver_abis;
CREATE INDEX IF NOT EXISTS idx_resolver_abis_namehash ON resolver_abis(namehash);

-- ============================================================================
-- resolver_names: namehash UNIQUE -> UNIQUE(protocol, resolver, namehash)
-- ============================================================================
CREATE TABLE IF NOT EXISTS resolver_names_new (
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
INSERT OR IGNORE INTO resolver_names_new
  SELECT id, namehash, resolver, name, protocol, block_number, transaction_hash, timestamp
  FROM resolver_names;
DROP TABLE resolver_names;
ALTER TABLE resolver_names_new RENAME TO resolver_names;
CREATE INDEX IF NOT EXISTS idx_resolver_names_namehash ON resolver_names(namehash);

-- ============================================================================
-- resolver_interfaces: UNIQUE(namehash, interface_id) -> UNIQUE(protocol, resolver, namehash, interface_id)
-- ============================================================================
CREATE TABLE IF NOT EXISTS resolver_interfaces_new (
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
INSERT OR IGNORE INTO resolver_interfaces_new
  SELECT id, namehash, resolver, interface_id, implementer, protocol, block_number, transaction_hash, timestamp
  FROM resolver_interfaces;
DROP TABLE resolver_interfaces;
ALTER TABLE resolver_interfaces_new RENAME TO resolver_interfaces;
CREATE INDEX IF NOT EXISTS idx_resolver_interfaces_namehash ON resolver_interfaces(namehash);

-- ============================================================================
-- resolver_versions: PRIMARY KEY(namehash) -> composite (resolver, namehash)
-- ============================================================================
CREATE TABLE IF NOT EXISTS resolver_versions_new (
  namehash TEXT NOT NULL,
  resolver TEXT NOT NULL,
  version INTEGER NOT NULL,
  protocol TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  PRIMARY KEY (resolver, namehash)
);
INSERT OR IGNORE INTO resolver_versions_new
  SELECT namehash, resolver, version, protocol, block_number, transaction_hash, timestamp
  FROM resolver_versions;
DROP TABLE resolver_versions;
ALTER TABLE resolver_versions_new RENAME TO resolver_versions;
