-- ENSv2 Indexer Database Schema
-- Migration 019: Add contract_address to EAC roles
-- Added: 2026-02-27 for tracking which contract emitted EACRolesChanged
-- This enables querying role holders per resolver contract address
-- NOTE: For fresh DBs, contract_address is already included in 003_eac_roles.sql.
-- This migration only applies to existing DBs (handled by migrate() in database.zig).
-- The index is safe to re-create with IF NOT EXISTS.

CREATE INDEX IF NOT EXISTS idx_eac_roles_contract ON eac_roles(protocol, contract_address);
