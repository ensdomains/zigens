#!/bin/bash
#
# ENS Rainbow Table Builder
#
# Downloads The Graph's rainbow preimage data and builds optimized SQLite database.
#
# Requirements:
#   - gsutil (Google Cloud SDK): brew install google-cloud-sdk
#   - python3
#   - sqlite3
#
# Output:
#   ./data/ens_rainbow.db (~2.5-3GB)
#
# Usage:
#   ./scripts/build_rainbow.sh
#
# License: MIT

set -e

echo "╔════════════════════════════════════════════╗"
echo "║   ENS Rainbow Table Builder                ║"
echo "║   Source: The Graph Protocol (MIT)        ║"
echo "║   Target: ~133M labels, ~2.5-3GB          ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# Check requirements
command -v gsutil >/dev/null 2>&1 || {
    echo "❌ Error: gsutil not found"
    echo ""
    echo "Install Google Cloud SDK:"
    echo "  brew install google-cloud-sdk"
    echo ""
    exit 1
}

command -v python3 >/dev/null 2>&1 || {
    echo "❌ Error: python3 not found"
    exit 1
}

command -v sqlite3 >/dev/null 2>&1 || {
    echo "❌ Error: sqlite3 not found"
    exit 1
}

# Configuration
RAINBOW_DATA_DIR="./rainbow_data"
DB_PATH="./data/ens_rainbow.db"

# Step 1: Download data
echo "📥 Step 1: Downloading rainbow data from Google Cloud Storage"
echo "   This will download ~6GB of data..."
echo ""

mkdir -p "$RAINBOW_DATA_DIR"
cd "$RAINBOW_DATA_DIR"

# Check if already downloaded
if ls preimages-* 1> /dev/null 2>&1; then
    echo "✅ Preimage files already exist in $RAINBOW_DATA_DIR"
    echo "   Skipping download (delete files to re-download)"
else
    echo "Downloading preimage files..."
    gsutil -m cp "gs://ens-files/preimages/preimages-*" .

    if [ $? -ne 0 ]; then
        echo "❌ Download failed"
        exit 1
    fi

    echo "✅ Download complete"
fi

cd ..

# Show downloaded files
echo ""
echo "Downloaded files:"
ls -lh "$RAINBOW_DATA_DIR" | head -10
echo ""

# Step 2: Build database
echo "🗃️  Step 2: Building optimized SQLite database"
echo "   This will take 10-20 minutes..."
echo ""

# Make parser executable
chmod +x ./scripts/parse_rainbow.py

# Process data
cat "$RAINBOW_DATA_DIR"/preimages-* | python3 ./scripts/parse_rainbow.py

if [ $? -ne 0 ]; then
    echo "❌ Import failed"
    exit 1
fi

# Step 3: Verify
echo ""
echo "✅ Step 3: Verifying database"
echo ""

sqlite3 "$DB_PATH" << 'EOF'
.mode column
.headers on

SELECT 'Rainbow Table Statistics' as info;
SELECT key, value FROM rainbow_metadata;

SELECT 'Sample Labels' as info;
SELECT label FROM rainbow_labels LIMIT 10;
EOF

echo ""
echo "╔════════════════════════════════════════════╗"
echo "║   ✅ Rainbow Table Build Complete!        ║"
echo "╚════════════════════════════════════════════╝"
echo ""
echo "Database location: $DB_PATH"
echo "Database size: $(du -h "$DB_PATH" | cut -f1)"
echo ""
echo "Usage in Zig:"
echo "  var rainbow = try Rainbow.init(allocator, \"$DB_PATH\");"
echo "  defer rainbow.deinit();"
echo "  const label = try rainbow.lookup(labelhash);"
echo ""
echo "Next steps:"
echo "  1. Test with: zig build test"
echo "  2. Use in indexer: ./zig-out/bin/ensv2-indexer-v1"
echo ""
