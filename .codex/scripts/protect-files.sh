#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <file-path> [file-path...]" >&2
  exit 2
fi

protected_patterns=(
  ".env"
  ".env.local"
  ".env.production"
  "package-lock.json"
  ".git/"
  "amplify.yml"
)

for file_path in "$@"; do
  for pattern in "${protected_patterns[@]}"; do
    if [[ "$file_path" == *"$pattern"* ]]; then
      echo "BLOCKED: Cannot edit protected file: $file_path" >&2
      echo "Ask the user for explicit permission before touching this file." >&2
      exit 2
    fi
  done
done

exit 0

