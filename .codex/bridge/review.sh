#!/usr/bin/env bash
set -e

TMP=$(mktemp)

cat > "$TMP"

echo "=== Codex Review ==="
codex exec "$TMP"

rm "$TMP"
