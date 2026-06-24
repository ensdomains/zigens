#!/bin/bash
#
# API entrypoint script for ENSv2 API
# Waits for database to exist before starting the API server
#

set -e

echo "ENSv2 API Server starting..."

# Postgres backend (DATABASE_URL / DATABASE_BACKEND=postgres): there is no local DB
# file to wait for — the server connects directly (checkIntegrity is a SELECT 1, and
# the driver retries the initial connect for managed-PG cold starts). Only the SQLite
# backend needs to wait for the indexer to create the database file.
case "${DATABASE_BACKEND:-}" in
    postgres | postgresql) is_pg=1 ;;
    *) if [ -n "${DATABASE_URL:-}" ]; then is_pg=1; else is_pg=0; fi ;;
esac

if [ "$is_pg" = "1" ]; then
    echo "Postgres backend detected; skipping local DB file wait."
else
    DATABASE="${DATABASE_PATH:-/app/data/ens_v2.db}"
    MAX_WAIT=${MAX_WAIT_SECONDS:-600} # Default: wait up to 10 minutes
    echo "Waiting for database at: $DATABASE"

    # Wait for the database file to exist
    elapsed=0
    while [ ! -f "$DATABASE" ]; do
        if [ $elapsed -ge $MAX_WAIT ]; then
            echo "ERROR: Timeout waiting for database after ${MAX_WAIT} seconds"
            exit 1
        fi

        echo "Database not ready, waiting... (${elapsed}s/${MAX_WAIT}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "Database found!"
fi

echo "Starting API server..."

# Execute the API server
exec /app/ensv2-api
