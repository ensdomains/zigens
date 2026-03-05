-- ENSv2 Indexer Database Schema
-- Migration 019: Add contract_address to EAC roles
-- Added: 2026-02-27 for tracking which contract emitted EACRolesChanged
-- This enables querying role holders per resolver contract address

ALTER TABLE eac_roles ADD COLUMN contract_address TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_eac_roles_contract ON eac_roles(chain, contract_address);
