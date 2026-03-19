#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
PROMPT_FILE="${2:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ID="$STAMP"
RUN_DIR="$ROOT/.claude/artifacts/$RUN_ID"
CURRENT_FILE="$ROOT/.claude/artifacts/current.txt"
CURRENT_LINK="$ROOT/.claude/artifacts/current"

if [ -z "$PROMPT_FILE" ]; then
  echo "Uso: bash .claude/pipeline/run.sh <repo> <brief.md>"
  exit 1
fi

mkdir -p "$RUN_DIR"

cp "$PROMPT_FILE" "$RUN_DIR/brief.md"

cat > "$RUN_DIR/pre-check.md" <<'PRECHECK'
# Pre-check

Objetivo:
- confirmar contexto
- identificar riscos
- identificar ficheiros prováveis
- identificar dúvidas reais
- não implementar ainda
PRECHECK

cat > "$RUN_DIR/plan.md" <<'PLAN'
# Plan

Objetivo:
- decompor a tarefa em passos atómicos
- definir abordagem
- identificar impacto
- definir validações
PLAN

cat > "$RUN_DIR/build-report.md" <<'BUILD'
# Build Report

Objetivo:
- registar o que foi alterado
- registar decisões
- registar limitações
BUILD

cat > "$RUN_DIR/qa-report.md" <<'QA'
# QA Report

Objetivo:
- validar resultado
- listar falhas
- listar riscos remanescentes
- decidir se fica aprovado, aprovado com reservas ou rejeitado
QA

printf '%s\n' ".claude/artifacts/$RUN_ID" > "$CURRENT_FILE"
ln -sfn "$RUN_ID" "$CURRENT_LINK"

echo "Pipeline preparado em: $RUN_DIR"
echo
echo "Ficheiros criados:"
echo "  - brief.md"
echo "  - pre-check.md"
echo "  - plan.md"
echo "  - build-report.md"
echo "  - qa-report.md"
