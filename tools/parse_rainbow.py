#!/usr/bin/env python3
"""
ENS Rainbow Table Import Script

Converts The Graph's rainbow preimage data to optimized SQLite format.

Input: JSONL preimage data from stdin
  Format: {"t": "label"}\n
  Example: {"t": "vitalik"}\n

Output: SQLite database with binary labelhash storage
  Location: ./data/ens_rainbow.db
  Size: ~2.5-3GB (vs 6GB original)

Usage:
  cat preimages-* | python3 scripts/parse_rainbow.py

License: MIT
"""

import sys
import sqlite3
import os
import json

# Use eth_hash for correct Keccak-256 (NOT SHA3-256!)
# SHA3-256 is the NIST standard, Keccak-256 is what Ethereum uses
try:
    from eth_hash.auto import keccak as keccak_func
    def keccak256(data):
        """Compute keccak256 hash (Ethereum-compatible)"""
        if isinstance(data, str):
            data = data.encode('utf-8')
        return keccak_func(data)
except ImportError:
    print("ERROR: eth_hash library not found!", file=sys.stderr)
    print("Install it with: pip3 install eth-hash[pycryptodome]", file=sys.stderr)
    sys.exit(1)

def hex_to_bytes(hex_str):
    """Convert 0x-prefixed hex string to bytes"""
    if hex_str.startswith('0x'):
        hex_str = hex_str[2:]
    return bytes.fromhex(hex_str)

def main():
    db_path = './data/ens_rainbow.db'

    # Ensure data directory exists
    os.makedirs('./data', exist_ok=True)

    # Connect to SQLite
    print(f'Creating database at {db_path}...', file=sys.stderr)
    db = sqlite3.connect(db_path)
    cursor = db.cursor()

    # Create optimized schema
    print('Creating optimized schema...', file=sys.stderr)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS rainbow_labels (
            labelhash BLOB PRIMARY KEY,
            label TEXT NOT NULL
        ) WITHOUT ROWID
    ''')

    # Create metadata table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS rainbow_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    ''')

    # Optimize for bulk insert
    cursor.execute('PRAGMA page_size = 4096')
    cursor.execute('PRAGMA cache_size = 1000000')
    cursor.execute('PRAGMA temp_store = memory')
    cursor.execute('PRAGMA synchronous = NORMAL')
    cursor.execute('PRAGMA journal_mode = WAL')

    # Begin transaction
    cursor.execute('BEGIN TRANSACTION')

    count = 0
    batch = []
    BATCH_SIZE = 10000

    print('Importing labels...', file=sys.stderr)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            # Parse JSONL format: {"t": "label"}
            data = json.loads(line)
            if 't' not in data:
                continue

            label = data['t']

            # Compute labelhash using keccak256
            labelhash_binary = keccak256(label)

            if len(labelhash_binary) != 32:
                print(f'Warning: Invalid labelhash length for label: {label}', file=sys.stderr)
                continue

            batch.append((labelhash_binary, label))
            count += 1

            # Batch insert for performance
            if len(batch) >= BATCH_SIZE:
                cursor.executemany(
                    'INSERT OR IGNORE INTO rainbow_labels (labelhash, label) VALUES (?, ?)',
                    batch
                )
                batch = []

                # Commit periodically
                if count % 1000000 == 0:
                    print(f'  Processed {count:,} labels...', file=sys.stderr)
                    db.commit()
                    cursor.execute('BEGIN TRANSACTION')

        except Exception as e:
            print(f'Warning: Failed to process line: {line[:100]}... Error: {e}', file=sys.stderr)
            continue

    # Insert remaining batch
    if batch:
        cursor.executemany(
            'INSERT OR IGNORE INTO rainbow_labels (labelhash, label) VALUES (?, ?)',
            batch
        )

    db.commit()

    print(f'✅ Total labels imported: {count:,}', file=sys.stderr)

    # Update metadata
    print('Updating metadata...', file=sys.stderr)
    cursor.execute('''
        INSERT OR REPLACE INTO rainbow_metadata (key, value) VALUES
        ('version', '1.0'),
        ('source', 'thegraph-ens-rainbow'),
        ('import_date', datetime('now')),
        ('record_count', ?)
    ''', (str(count),))

    db.commit()

    # Optimize database
    print('Optimizing database...', file=sys.stderr)
    cursor.execute('VACUUM')
    cursor.execute('ANALYZE')
    cursor.execute('PRAGMA optimize')

    db.close()

    print(f'✅ Rainbow table build complete!', file=sys.stderr)
    print(f'   Location: {db_path}', file=sys.stderr)

    # Show final size
    size_bytes = os.path.getsize(db_path)
    size_gb = size_bytes / (1024**3)
    print(f'   Size: {size_gb:.2f} GB ({size_bytes:,} bytes)', file=sys.stderr)

if __name__ == '__main__':
    main()
