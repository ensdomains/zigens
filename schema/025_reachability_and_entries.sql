-- ENSv2 Indexer Database Schema
-- Migration 025: Reachability tracking + on-chain Entry mirror
--
-- Fixes "orphaned descendants on subregistry repoint": when a parent registry
-- calls setSubregistry() to repoint a label to a new subregistry contract,
-- the previous subregistry's tokens (and all descendants under it) become
-- unreachable via canonical top-down resolution. Without this migration the
-- indexer leaves them in `names` indefinitely.
--
-- New table `registry_entries` mirrors the on-chain PermissionedRegistry.Entry
-- mapping per (parent_registry, canonical_id), so SubregistryUpdated can
-- compare the previous subregistry pointer against the new one and cascade
-- invalidate descendants when they differ.
--
-- New columns `is_reachable` / `unreachable_since` on `names` provide a soft
-- delete so reactivation is possible if the parent later re-points back to
-- the original subregistry.

-- ============================================================================
-- NAMES: reachability columns
-- ============================================================================

ALTER TABLE names ADD COLUMN is_reachable INTEGER NOT NULL DEFAULT 1;
ALTER TABLE names ADD COLUMN unreachable_since INTEGER;

CREATE INDEX IF NOT EXISTS idx_names_is_reachable ON names(protocol, is_reachable);
CREATE INDEX IF NOT EXISTS idx_names_registry_reachable ON names(protocol, registry, is_reachable);

-- ============================================================================
-- REGISTRY_ENTRIES: on-chain Entry mirror keyed by (parent_registry, canonical_id)
-- ============================================================================

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

-- BFS by `subregistry` is how we collect descendants when invalidating a subtree.
CREATE INDEX IF NOT EXISTS idx_registry_entries_subregistry
  ON registry_entries(protocol, subregistry);

CREATE INDEX IF NOT EXISTS idx_registry_entries_parent
  ON registry_entries(protocol, parent_registry);
