-- ENSv2 Indexer Database Schema
-- Migration 004: ENSIP-16 Offchain Metadata Support
-- Added: 2025-01-28 for CCIP Read resolver metadata

-- ============================================================================
-- RESOLVER METADATA (Offchain GraphQL endpoints)
-- ============================================================================

CREATE TABLE IF NOT EXISTS resolver_metadata (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  resolver TEXT NOT NULL,           -- Resolver contract address
  graphql_url TEXT NOT NULL,         -- Offchain GraphQL endpoint
  block_number INTEGER NOT NULL,
  transaction_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  UNIQUE(protocol, resolver)
);

CREATE INDEX IF NOT EXISTS idx_resolver_metadata_protocol ON resolver_metadata(protocol);
CREATE INDEX IF NOT EXISTS idx_resolver_metadata_resolver ON resolver_metadata(protocol, resolver);

-- ============================================================================
-- RESOLVER APPROVALS (Delegation tracking for ENSIP-16)
-- ============================================================================

CREATE TABLE IF NOT EXISTS resolver_approvals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  resolver TEXT NOT NULL,           -- Resolver contract address
  namehash TEXT NOT NULL,            -- Name being delegated
  context TEXT,                      -- Optional context for namespacing (typically owner address)
  delegate TEXT NOT NULL,            -- Address being approved
  approved INTEGER NOT NULL,         -- 1 = approved, 0 = revoked
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

-- ============================================================================
-- UPDATE EXISTING TABLES: Add context field for namespacing
-- ============================================================================

-- Note: These ALTER TABLE statements have been commented out because they were
-- already applied. SQLite doesn't support IF NOT EXISTS for ALTER TABLE ADD COLUMN.
-- If you're setting up a fresh database, uncomment these lines.

-- Add context column to resolver_addresses if it doesn't exist
-- Context allows multiple entities to manage the same name independently
ALTER TABLE resolver_addresses ADD COLUMN context TEXT DEFAULT NULL;

-- Add context column to resolver_contenthashes if it doesn't exist
ALTER TABLE resolver_contenthashes ADD COLUMN context TEXT DEFAULT NULL;

-- Add context column to resolver_texts if it doesn't exist
ALTER TABLE resolver_texts ADD COLUMN context TEXT DEFAULT NULL;

-- Create new indexes for context-aware queries
CREATE INDEX IF NOT EXISTS idx_resolver_addresses_context ON resolver_addresses(protocol, namehash, context);
CREATE INDEX IF NOT EXISTS idx_resolver_contenthashes_context ON resolver_contenthashes(protocol, namehash, context);
CREATE INDEX IF NOT EXISTS idx_resolver_texts_context ON resolver_texts(protocol, namehash, context);
