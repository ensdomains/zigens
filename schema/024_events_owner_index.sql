-- ENSv2 Indexer Database Schema
-- Migration 024: Expression index on events.data $.owner
--
-- Owner-filtered queries (e.g. registrationConnection.where.registrant) generate:
--   WHERE LOWER(json_extract(data, '$.owner')) = LOWER(?)
-- Without an index, SQLite must scan every events row + parse the JSON blob per row.
-- That cost grows linearly with the events table forever.
--
-- SQLite (≥3.9) supports indexes on expressions. The planner picks up this index
-- automatically as long as the WHERE clause expression matches the index expression
-- byte-for-byte — which the storage layer code at storage/events.zig:264, 269, 480,
-- 485, 831 emits exactly.
--
-- Equivalent on Postgres after migration:
--   CREATE INDEX ON events (LOWER(data->>'owner'));
-- so this approach carries cleanly across the planned DB switch.

CREATE INDEX IF NOT EXISTS idx_events_owner_extracted
    ON events (LOWER(json_extract(data, '$.owner')));
