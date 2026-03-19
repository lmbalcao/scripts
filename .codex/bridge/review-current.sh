#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
MODE="${2:-summary}"
CURRENT_FILE="$ROOT/.claude/artifacts/current.txt"

if [ ! -f "$CURRENT_FILE" ]; then
  echo "Não existe current.txt em: $CURRENT_FILE"
  exit 1
fi

RUN_REF="$(tr -d '\n' < "$CURRENT_FILE")"

if [ -z "$RUN_REF" ]; then
  echo "current.txt está vazio"
  exit 1
fi

bash "$ROOT/.codex/bridge/review-run.sh" "$ROOT" "$RUN_REF" "$MODE"
