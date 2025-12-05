#!/bin/bash
#
# API entrypoint script for ENSv2 API
# Waits for database to exist before starting the API server
#

set -e

DATABASE="${DATABASE_PATH:-/app/data/ens_v2.db}"
MAX_WAIT=${MAX_WAIT_SECONDS:-600}  # Default: wait up to 10 minutes

echo "ENSv2 API Server starting..."
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

echo "Database found! Starting API server..."

# Execute the API server
exec /app/ensv2-api
