#!/usr/bin/env python3
"""Diff a `--backfill` rebuild against the live database it was rebuilt from.

This is the gate the test suite cannot be: the suites prove replay parity on synthetic
fixtures, but only real event history exercises the orderings, the phase boundaries and the
long tail of shapes that actually diverge. Several fixes exist *specifically* to make live and
replay comparable, so this is what proves them rather than arguing them.

    tools/replay_diff.py --baseline ./live.db --replayed ./rebuilt.db
    tools/replay_diff.py --baseline 'postgresql://u:p@host/live' \\
                         --replayed 'postgresql://u:p@host/rebuilt'

How to produce the two databases (NEVER rewind sync_state on the live one — clone it):

    # 1. stop the indexer, or snapshot while it is stopped
    cp live.db rebuilt.db                      # SQLite
    createdb rebuilt && pg_dump live | psql rebuilt   # Postgres
    # 2. rebuild the projections in the CLONE from its own stored events
    DATABASE_PATH=./rebuilt.db ./zig-out/bin/ensv2-indexer --backfill
    # 3. compare
    tools/replay_diff.py --baseline ./live.db --replayed ./rebuilt.db

Exit status is 0 only when every compared table matches.

Comparison model
----------------
For each table: take its column list from the database itself, drop the columns listed as
known-divergent below, then order rows by the full remaining content. Two databases built from
the same events therefore produce byte-identical dumps, with no need for a per-table key — the
same model `tests/integration.zig`'s `reconcileEqual` uses for the reorg invariant.

Known-divergent columns are per-table and each carries its reason. That matters: a blanket
ignore list hides the very divergences this tool exists to find. `docs/indexer-resolution-audit-2026-09-20.md`
tracks which of these are bugs awaiting a fix versus intended.
"""

import argparse
import os
import shutil
import sqlite3
import subprocess
import sys
from collections import OrderedDict

# Projection tables a replay rebuilds. Mirrors RECONCILE_TABLES in tests/integration.zig.
TABLES = [
    "names", "registries", "registrations", "registry_entries",
    "resolvers", "resolver_addresses", "resolver_contenthashes", "resolver_texts",
    "resolver_aliases", "resolver_pubkeys", "resolver_abis", "resolver_names",
    "resolver_interfaces", "resolver_versions", "resolver_metadata", "resolver_approvals",
    "resolver_dns_records", "resolver_dns_zonehashes", "resolver_authorisations",
    "reverse_records", "approvals", "eac_roles", "accounts", "v1_controllers",
    "name_history", "resolver_links", "resolver_named_resources", "unknown_labels",
]

# Columns excluded everywhere: the surrogate key is insertion order by construction, so it
# differs between any two builds and says nothing about content.
GLOBAL_IGNORE = {"id"}

# Per-table exclusions, each with the reason. Anything NOT listed here is compared — including
# every block-derived column (block_number, *_block, expiry, registered_at, …), which is the
# point: those must match, and a mismatch is a real replay bug.
#
# "KNOWN BUG" entries are tracked in docs/indexer-resolution-audit-2026-09-20.md and should
# shrink over time; delete the entry once the writer is fixed and the column starts matching.
PER_TABLE_IGNORE = {
    # KNOWN BUG (audit §2): names.updated_at is zsys.timestamp() — the indexer's wall clock —
    # on every single-field update path, so no rebuild can reproduce it. created_at is
    # block-derived on the insert paths but wall-clock on some update paths.
    "names": {"updated_at", "created_at"},
    # KNOWN BUG (audit §2): resolver_metadata.timestamp is written at write time, not derived
    # from the block.
    "resolver_metadata": {"timestamp"},
    # Wall clock on write; not block-derived.
    "resolvers": {"set_at"},
    "registries": {"created_at"},
    "approvals": {"timestamp"},
    "accounts": {"first_seen_timestamp", "last_seen_timestamp"},
    # NOTE: eac_roles.timestamp is deliberately NOT ignored any more. It used to be
    # zsys.timestamp() and was therefore unreproducible; it is now the block timestamp, so
    # comparing it is how this tool verifies that fix.
}

MAX_SAMPLES = 8


def is_postgres(target: str) -> bool:
    return target.startswith(("postgres://", "postgresql://"))


class Source:
    """A database to dump from. Uses the stdlib for SQLite and `psql` for Postgres, so the
    tool has no third-party dependency on either side."""

    def __init__(self, target: str):
        self.target = target
        self.pg = is_postgres(target)
        if self.pg:
            if shutil.which("psql") is None:
                sys.exit("error: psql not found on PATH, needed for a postgresql:// target")
        else:
            if not os.path.exists(target):
                sys.exit(f"error: no such SQLite database: {target}")
            # Read-only, and immutable so no -wal/-shm is created next to someone's live file.
            self.conn = sqlite3.connect(f"file:{target}?mode=ro&immutable=1", uri=True)

    def query(self, sql: str):
        if self.pg:
            out = subprocess.run(
                ["psql", self.target, "-At", "-F", "\x1f", "-c", sql],
                capture_output=True, text=True,
            )
            if out.returncode != 0:
                sys.exit(f"error: psql failed on {self.target}:\n{out.stderr.strip()}")
            return [line.split("\x1f") for line in out.stdout.splitlines()]
        cur = self.conn.execute(sql)
        return [["" if v is None else str(v) for v in row] for row in cur.fetchall()]

    def columns(self, table: str):
        if self.pg:
            rows = self.query(
                "SELECT column_name FROM information_schema.columns "
                f"WHERE table_name = '{table}' "
                "AND table_schema = COALESCE(current_schema(), 'public') "
                "ORDER BY ordinal_position"
            )
            return [r[0] for r in rows]
        try:
            cur = self.conn.execute(f"PRAGMA table_info({table})")
        except sqlite3.Error:
            return []
        return [r[1] for r in cur.fetchall()]

    def dump(self, table: str, cols):
        """Every row, compared columns only, ordered by full content."""
        if not cols:
            return []
        sel = ", ".join(f'COALESCE(CAST("{c}" AS TEXT), \'~\')' for c in cols)
        order = ", ".join(str(i + 1) for i in range(len(cols)))
        rows = self.query(f"SELECT {sel} FROM {table} ORDER BY {order}")
        return ["\x1f".join(r) for r in rows]


def diff_table(table, base: Source, repl: Source):
    base_cols = base.columns(table)
    repl_cols = repl.columns(table)
    if not base_cols and not repl_cols:
        return ("skipped", "table absent from both databases", 0, [])
    if base_cols != repl_cols:
        return ("SCHEMA", f"column lists differ: {base_cols} vs {repl_cols}", 0, [])

    ignore = GLOBAL_IGNORE | PER_TABLE_IGNORE.get(table, set())
    cols = [c for c in base_cols if c not in ignore]
    if not cols:
        return ("skipped", "every column is excluded", 0, [])

    a = base.dump(table, cols)
    b = repl.dump(table, cols)
    if a == b:
        return ("ok", f"{len(a)} rows identical over {len(cols)} columns", len(a), [])

    only_base = OrderedDict()
    for row in a:
        only_base[row] = only_base.get(row, 0) + 1
    for row in b:
        if row in only_base:
            only_base[row] -= 1
            if only_base[row] == 0:
                del only_base[row]
    only_repl = OrderedDict()
    for row in b:
        only_repl[row] = only_repl.get(row, 0) + 1
    for row in a:
        if row in only_repl:
            only_repl[row] -= 1
            if only_repl[row] == 0:
                del only_repl[row]

    samples = []
    for row in list(only_base)[:MAX_SAMPLES]:
        samples.append(("live only ", dict(zip(cols, row.split("\x1f")))))
    for row in list(only_repl)[:MAX_SAMPLES]:
        samples.append(("replay only", dict(zip(cols, row.split("\x1f")))))

    msg = (
        f"{len(a)} live rows vs {len(b)} replayed; "
        f"{sum(only_base.values())} only in live, {sum(only_repl.values())} only in replay"
    )
    return ("DIFF", msg, len(a), samples)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", required=True, help="the live database (SQLite path or postgresql:// URL)")
    ap.add_argument("--replayed", required=True, help="the --backfill rebuild of a CLONE of it")
    ap.add_argument("--tables", help="comma-separated subset to check")
    ap.add_argument("--quiet", action="store_true", help="only print problems")
    args = ap.parse_args()

    base = Source(args.baseline)
    repl = Source(args.replayed)
    tables = args.tables.split(",") if args.tables else TABLES

    problems = 0
    for table in tables:
        status, msg, rows, samples = diff_table(table.strip(), base, repl)
        if status in ("DIFF", "SCHEMA"):
            problems += 1
            print(f"\n=== {status}: {table} ===\n  {msg}")
            for side, row in samples:
                shown = {k: v for k, v in row.items() if v not in ("", "~")}
                print(f"    [{side}] {shown}")
        elif not args.quiet:
            mark = "ok " if status == "ok" else "-- "
            print(f"{mark}{table}: {msg}")

    print()
    if problems:
        print(f"FAIL: {problems} table(s) diverge between live and replay.")
        print("Each divergence is either a replay bug or a column that belongs in")
        print("PER_TABLE_IGNORE with a documented reason — never silently the latter.")
        return 1
    print(f"PASS: all {len(tables)} table(s) identical (excluding documented non-deterministic columns).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
