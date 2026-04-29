-- Migration: Fix subregistry address reuse bug
-- Problem: UNIQUE(protocol, address) constraint causes later SubregistryUpdate events to
-- overwrite earlier ones when the same contract address is used as a subregistry for
-- multiple parent names (e.g., fox.eth and records.eth both using 0x959661...)
-- Solution: Change constraint to UNIQUE(protocol, address, namehash) to allow same address
-- for different parent names

-- Step 1: Create new table with correct constraint
CREATE TABLE IF NOT EXISTS registries_new (
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

-- Step 2: Copy existing data (handles duplicates by keeping newer entries)
INSERT OR IGNORE INTO registries_new (protocol, address, name, namehash, parent_registry, created_block, created_at)
SELECT protocol, address, name, namehash, parent_registry, created_block, created_at
FROM registries
ORDER BY created_block ASC;

-- Step 3: Drop old table and rename new one
DROP TABLE IF EXISTS registries;
ALTER TABLE registries_new RENAME TO registries;

-- Step 4: Recreate indexes
CREATE INDEX IF NOT EXISTS idx_registries_protocol ON registries(protocol);
CREATE INDEX IF NOT EXISTS idx_registries_namehash ON registries(namehash);
-- Composite index for efficient parent lookup by address and block (covers ORDER BY created_block DESC)
CREATE INDEX IF NOT EXISTS idx_registries_address_block ON registries(protocol, address, created_block DESC);
