#!/bin/bash
#
# Health check script for ENSv2 Indexer
# Returns healthy if:
# 1. Rainbow download is in progress (marker file exists), OR
# 2. Status server is responding on port 3001
#

RAINBOW_DOWNLOADING_MARKER="/app/data/.rainbow_downloading"
STATUS_URL="http://localhost:3001/status"

# If rainbow is downloading, consider healthy (still initializing)
if [ -f "$RAINBOW_DOWNLOADING_MARKER" ]; then
    echo "Rainbow download in progress..."
    exit 0
fi

# Otherwise, check if status server is responding
if wget --no-verbose --tries=1 --spider "$STATUS_URL" 2>/dev/null; then
    exit 0
else
    exit 1
fi
