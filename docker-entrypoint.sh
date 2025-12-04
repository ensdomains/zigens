#!/bin/bash
#
# Docker entrypoint for ENSv2 Indexer
# Downloads rainbow table on first startup if DOWNLOAD_RAINBOW=true
#

set -e

RAINBOW_DB="${RAINBOW_PATH:-/app/data/ens_rainbow.db}"
RAINBOW_DATA_DIR="/app/rainbow_data"
RAINBOW_DOWNLOADING_MARKER="/app/data/.rainbow_downloading"

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

    # Check if gsutil is available
    if ! command -v gsutil &> /dev/null; then
        echo "WARNING: gsutil not found, skipping rainbow table download"
        echo "Labels will show as [unknown] for unhashed names"
        return 0
    fi

    echo "Downloading rainbow data from Google Cloud Storage..."
    echo "This will download ~6GB and take 10-20 minutes..."
    echo ""

    mkdir -p "$RAINBOW_DATA_DIR"

    # Download preimage files
    if gsutil -m cp "gs://ens-files/preimages/preimages-*" "$RAINBOW_DATA_DIR/"; then
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

                # Remove downloading marker
                rm -f "$RAINBOW_DOWNLOADING_MARKER"
            else
                echo "ERROR: Rainbow database was not created"
                rm -f "$RAINBOW_DOWNLOADING_MARKER"
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

# Check if rainbow table needs to be downloaded
if [ "$DOWNLOAD_RAINBOW" = "true" ] && [ ! -f "$RAINBOW_DB" ]; then
    echo "Rainbow table not found at $RAINBOW_DB"
    echo "Starting download..."
    build_rainbow
elif [ -f "$RAINBOW_DB" ]; then
    echo "Rainbow table found at $RAINBOW_DB ($(du -h "$RAINBOW_DB" | cut -f1))"
fi

# Execute the main command
echo "Starting: $@"
exec "$@"
