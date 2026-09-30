# replay_diff.py

Proves that `--backfill` reproduces the database a live run produced. Stdlib only on SQLite;
uses `psql` for Postgres. No install step.

This is the gate the test suites cannot be. They prove replay parity on synthetic fixtures;
only real event history exercises the orderings, phase boundaries and long tail of shapes that
actually diverge. Several fixes landed specifically to make live and replay comparable — this
is what proves them instead of arguing them.

## Producing the two databases

**Never rewind `sync_state` on the live database — clone it.** The clone is what gets rebuilt.

```bash
# stop the indexer first (or snapshot while stopped)

# --- SQLite
cp live.db rebuilt.db
DATABASE_PATH=./rebuilt.db ./zig-out/bin/ensv2-indexer --backfill

# --- Postgres
createdb rebuilt && pg_dump live | psql rebuilt
DATABASE_URL=postgresql://…/rebuilt ./zig-out/bin/ensv2-indexer --backfill
```

Then:

```bash
tools/replay_diff.py --baseline ./live.db --replayed ./rebuilt.db
tools/replay_diff.py --baseline 'postgresql://…/live' --replayed 'postgresql://…/rebuilt'
```

Exit status is 0 only when every compared table matches, so it drops straight into CI.

## What it compares

28 projection tables (the list mirrors `RECONCILE_TABLES` in `tests/integration.zig`). Per
table it reads the column list from the database, drops the documented non-deterministic
columns, and orders rows by the full remaining content — so two databases built from the same
events produce byte-identical dumps and no per-table key is needed.

Every **block-derived** column is compared: `block_number`, `*_block`, `expiry`,
`registered_at`, `log_index`, `eac_roles.timestamp`, and so on. A mismatch in any of those is a
real replay bug, not noise.

## The ignore list is the interesting part

`PER_TABLE_IGNORE` is per table and every entry carries its reason. A blanket ignore list would
hide exactly what this tool exists to find, so entries marked **KNOWN BUG** are tracked in
`docs/indexer-resolution-audit-2026-09-20.md` and the list should shrink over time.

| table | column | why |
|---|---|---|
| all | `id` | AUTOINCREMENT — insertion order by construction, says nothing about content |
| `names` | `updated_at`, `created_at` | **KNOWN BUG** (audit §2): wall clock on the update paths, so no rebuild can reproduce it |
| `resolver_metadata` | `timestamp` | **KNOWN BUG** (audit §2): written at write time, not block-derived |
| `resolvers` | `set_at` | wall clock on write |
| `registries` | `created_at` | wall clock on write |
| `approvals` | `timestamp` | wall clock on write |
| `accounts` | `first_seen_timestamp`, `last_seen_timestamp` | wall clock on write |

`eac_roles.timestamp` is deliberately **not** ignored. It used to be `zsys.timestamp()` and was
therefore unreproducible; it is now the block timestamp, so comparing it is how this tool
verifies that fix.

**When a column starts matching, delete its entry.** That is the mechanism by which the
non-determinism actually gets paid down rather than permanently excused.

## Reading a failure

```
=== DIFF: names ===
  170369 live rows vs 170371 replayed; 0 only in live, 2 only in replay
    [replay only] {'name': 'blue.koala.eth', 'owner': '0x…', …}
```

`only in live` = the replay failed to produce a row (a dropped event arm — this is what the
missing `LabelUnregistered` arm looked like). `only in replay` = the replay produced something
live did not, or a compared column differs (a row appears on both sides, once per side). Row
counts equal with rows on both sides means a value diverged rather than a row going missing.

## Options

```
--tables names,eac_roles     restrict to a subset while iterating on one bug
--quiet                      only print problems (good for CI)
```

## Gotchas

- Both sides must be the **same backend**; a SQLite-vs-Postgres comparison would report type
  formatting differences rather than content ones.
- SQLite is opened read-only and `immutable=1`, so no `-wal`/`-shm` is created beside the file
  being read. Safe to point at a snapshot on shared storage.
- A `SCHEMA` result means the two databases are at different migration levels — rebuild the
  clone from the same binary before reading anything into the row diffs.
- The dump is materialised in memory on both sides: a 1.6M-row `names` table is roughly 1GB of
  Python strings. Use `--tables` to work table by table on a large database.
