#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <file-path> [file-path...]" >&2
  exit 2
fi

for file_path in "$@"; do
  if [[ "$file_path" =~ \.(ts|tsx|js|jsx)$ ]]; then
    if command -v npx >/dev/null 2>&1; then
      npx prettier --write "$file_path" 2>/dev/null || true
    fi
  fi
done

exit 0

