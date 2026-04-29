-- Migration 014: Add namehash index to names table
-- This improves performance of getNameByNamehash() lookups used during event processing
-- The existing UNIQUE(protocol, namehash) constraint creates a composite index that
-- cannot be efficiently used for queries on just namehash

CREATE INDEX IF NOT EXISTS idx_names_namehash ON names(namehash);
