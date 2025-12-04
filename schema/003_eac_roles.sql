-- ENSv2 Indexer Database Schema
-- Migration 003: Enhanced Access Control (EAC) Roles
-- Added: 2025-01-28 for role-based access control tracking

-- ============================================================================
-- EAC ROLES (Enhanced Access Control role assignments)
-- ============================================================================

CREATE TABLE IF NOT EXISTS eac_roles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain TEXT NOT NULL,
  resource TEXT NOT NULL,           -- Token ID or resource identifier
  account TEXT NOT NULL,             -- Address that has the role
  role_bitmap TEXT NOT NULL,         -- Hex string of role bitmap
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(chain, resource, account)
);

CREATE INDEX IF NOT EXISTS idx_eac_roles_chain ON eac_roles(chain);
CREATE INDEX IF NOT EXISTS idx_eac_roles_resource ON eac_roles(chain, resource);
CREATE INDEX IF NOT EXISTS idx_eac_roles_account ON eac_roles(chain, account);
CREATE INDEX IF NOT EXISTS idx_eac_roles_block ON eac_roles(chain, block_number);
