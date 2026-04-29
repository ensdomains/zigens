-- ENSv2 Indexer Database Schema
-- Migration 020: Registry-scoped unique constraints for cross-registry collision safety
-- Added: 2026-03-17
-- Fixes: token_id/resource collisions across registries (e.g., tester.eth vs tester.calendars.eth)

-- ============================================================================
-- EAC ROLES: Add contract_address to unique constraint
-- Old: UNIQUE(protocol, resource, account) — collides when same label exists in multiple registries
-- New: UNIQUE(protocol, resource, account, contract_address) — scoped per registry
-- ============================================================================

-- SQLite doesn't support ALTER TABLE to change constraints, so recreate the table
CREATE TABLE IF NOT EXISTS eac_roles_new (
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

INSERT OR IGNORE INTO eac_roles_new
  SELECT id, protocol, resource, account, role_bitmap, block_number, transaction_hash, log_index, timestamp, contract_address
  FROM eac_roles;

DROP TABLE eac_roles;
ALTER TABLE eac_roles_new RENAME TO eac_roles;

CREATE INDEX IF NOT EXISTS idx_eac_roles_protocol ON eac_roles(protocol);
CREATE INDEX IF NOT EXISTS idx_eac_roles_resource ON eac_roles(protocol, resource);
CREATE INDEX IF NOT EXISTS idx_eac_roles_account ON eac_roles(protocol, account);
CREATE INDEX IF NOT EXISTS idx_eac_roles_block ON eac_roles(protocol, block_number);
CREATE INDEX IF NOT EXISTS idx_eac_roles_contract ON eac_roles(protocol, contract_address);

-- ============================================================================
-- APPROVALS: Add registry column for cross-registry collision safety
-- Old: UNIQUE(protocol, token_id) — collides when same token_id exists in multiple registries
-- New: UNIQUE(protocol, token_id, registry) — scoped per registry
-- ============================================================================

CREATE TABLE IF NOT EXISTS approvals_new (
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

INSERT OR IGNORE INTO approvals_new
  SELECT id, protocol, token_id, owner, approved, block_number, tx_hash, timestamp, ''
  FROM approvals;

DROP TABLE approvals;
ALTER TABLE approvals_new RENAME TO approvals;

CREATE INDEX IF NOT EXISTS idx_approvals_protocol ON approvals(protocol);
CREATE INDEX IF NOT EXISTS idx_approvals_token_id ON approvals(token_id);
CREATE INDEX IF NOT EXISTS idx_approvals_owner ON approvals(owner);
