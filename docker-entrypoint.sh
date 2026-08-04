#!/bin/bash
#
# Docker entrypoint for ENSv2 Indexer
# Downloads rainbow table on first startup if DOWNLOAD_RAINBOW=true
#

set -e

RAINBOW_DB="${RAINBOW_PATH:-/app/data/ens_rainbow.db}"
RAINBOW_DATA_DIR="/app/rainbow_data"
export RAINBOW_DATA_DIR # read by the parallel download subshells
RAINBOW_DOWNLOADING_MARKER="/app/data/.rainbow_downloading"
# Never leave a stale "downloading" marker: set -e can abort the script mid-
# download/parse, which would otherwise pin the health check at "downloading"
# until restart. The trap does not fire on the final exec (process replaced) —
# by then the marker has already been removed after build_rainbow.
trap 'rm -f "$RAINBOW_DOWNLOADING_MARKER"' EXIT

# List preimage object names in the public bucket via the anonymous GCS JSON
# API (paginated), one per line. No SDK/credentials: the bucket is public —
# this script never carried any, gsutil was accessing it anonymously too.
list_preimage_objects() {
    python3 - <<'PY'
import json
import urllib.request

base = "https://storage.googleapis.com/storage/v1/b/ens-files/o?prefix=preimages/preimages-&fields=items/name,nextPageToken&maxResults=1000"
token = None
while True:
    url = base + ("&pageToken=" + token if token else "")
    with urllib.request.urlopen(url, timeout=60) as resp:
        page = json.load(resp)
    for item in page.get("items", []):
        print(item["name"])
    token = page.get("nextPageToken")
    if not token:
        break
PY
}

# Function to download and build rainbow table
build_rainbow() {
    # Create marker file so health check knows we're downloading
    touch "$RAINBOW_DOWNLOADING_MARKER"
    echo "╔════════════════════════════════════════════╗"
    echo "║   ENS Rainbow Table Download               ║"
    echo "║   Source: The Graph Protocol (MIT)         ║"
    echo "║   Target: ~133M labels, ~6GB               ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""

    if ! command -v curl &> /dev/null || ! command -v python3 &> /dev/null; then
        echo "WARNING: curl/python3 not found, skipping rainbow table download"
        echo "Labels will show as [unknown] for unhashed names"
        return 0
    fi

    echo "Downloading rainbow data from Google Cloud Storage..."
    echo "This will download ~6GB and take 10-20 minutes..."
    echo ""

    mkdir -p "$RAINBOW_DATA_DIR"

    # Download preimage files (4-way parallel, per-file retries)
    local objects
    objects=$(list_preimage_objects) || objects=""
    if [ -n "$objects" ] && printf '%s\n' "$objects" | xargs -P 4 -I{} sh -c \
        'curl -fsSL --retry 3 --retry-delay 5 -o "$RAINBOW_DATA_DIR/$(basename "$1")" "https://storage.googleapis.com/ens-files/$1"' _ {}; then
        echo "Download complete, building database..."

        # Build database using parse_rainbow.py
        if [ -f "/app/tools/parse_rainbow.py" ]; then
            cd /app
            cat "$RAINBOW_DATA_DIR"/preimages-* | python3 /app/tools/parse_rainbow.py

            if [ -f "$RAINBOW_DB" ]; then
                echo ""
                echo "Rainbow table built successfully!"
                echo "Database: $RAINBOW_DB"
                echo "Size: $(du -h "$RAINBOW_DB" | cut -f1)"

                # Cleanup downloaded files to save space
                rm -rf "$RAINBOW_DATA_DIR"
                echo "Cleaned up temporary files"
            else
                echo "ERROR: Rainbow database was not created"
            fi
        else
            echo "ERROR: parse_rainbow.py not found"
        fi
    else
        echo "ERROR: Failed to download rainbow data"
        echo "Continuing without rainbow table..."
    fi

    echo ""
}

# Rainbow table is only used by V1 indexing for labelhash resolution.
# Skip download when running the V2-only indexer to save ~6GB and 10-20 min.
case "$1" in
    */ensv2-indexer-v2)
        if [ "$DOWNLOAD_RAINBOW" = "true" ]; then
            echo "Running V2-only indexer — skipping rainbow table download (not needed for V2)"
            DOWNLOAD_RAINBOW=false
        fi
        ;;
esac

# Check if rainbow table needs to be downloaded
if [ "$DOWNLOAD_RAINBOW" = "true" ] && [ ! -f "$RAINBOW_DB" ]; then
    echo "Rainbow table not found at $RAINBOW_DB"
    echo "Starting download..."
    build_rainbow
    # Every build_rainbow outcome — success, soft failure, missing tools —
    # ends the "downloading" state the health check keys on.
    rm -f "$RAINBOW_DOWNLOADING_MARKER"
elif [ -f "$RAINBOW_DB" ]; then
    echo "Rainbow table found at $RAINBOW_DB ($(du -h "$RAINBOW_DB" | cut -f1))"
fi

# Execute the main command
echo "Starting: $@"
exec "$@"
