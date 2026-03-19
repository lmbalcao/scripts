#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "${1:-$PWD}" && pwd)"
RUN_REF="${2:-}"
MODE="${3:-summary}"

if [ "$MODE" = "--full" ]; then
  MODE="full"
fi

if [ -z "$RUN_REF" ]; then
  echo "Uso: bash .codex/bridge/review-run.sh <repo-root> <run-id|run-path> [summary|full]"
  exit 1
fi

resolve_run_dir() {
  local root="$1"
  local ref="$2"

  case "$ref" in
    /*)
      printf '%s\n' "$ref"
      ;;
    .claude/artifacts/*)
      printf '%s/%s\n' "$root" "$ref"
      ;;
    *)
      printf '%s/.claude/artifacts/%s\n' "$root" "$ref"
      ;;
  esac
}

artifact_snapshot() {
  local label="$1"
  local file="$2"
  local max_lines="${3:-24}"

  echo "## $label"
  echo

  if [ ! -f "$file" ]; then
    echo "_missing_"
    echo
    return
  fi

  python3 - "$file" "$max_lines" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
max_lines = int(sys.argv[2])
lines = path.read_text(errors="replace").splitlines()
selected = []
fallback = []

for raw in lines:
    line = raw.rstrip()
    stripped = line.strip()
    if not stripped:
        continue
    if stripped.startswith(("#", "##", "###", "- ", "* ", "|")) or "Verdict" in stripped or "Confidence" in stripped or "Status:" in stripped or "Result:" in stripped:
        selected.append(line)
    elif len(fallback) < max(4, max_lines // 4):
        fallback.append(line)

if not selected:
    selected = fallback
else:
    room = max_lines - len(selected)
    if room > 0:
        selected.extend(fallback[:room])

print("\n".join(selected[:max_lines]))
PY
  echo
}

RUN_DIR="$(resolve_run_dir "$ROOT" "$RUN_REF")"
OUT_FILE="$RUN_DIR/codex-review.md"
TMP_PROMPT="$(mktemp)"
TMP_JSONL="$(mktemp)"
TMP_ERR="$(mktemp)"

if [ ! -d "$RUN_DIR" ]; then
  echo "Run não encontrado: $RUN_DIR"
  exit 1
fi

if type -P codex >/dev/null 2>&1; then
  CODEX_CMD=("$(type -P codex)")
elif command -v npx >/dev/null 2>&1; then
  CODEX_CMD=(npx -y @openai/codex@latest)
else
  cat > "$OUT_FILE" <<'MARKDOWN'
# Codex Review

Estado: rejeitado

## Motivo
Codex CLI não encontrado e `npx` indisponível.

## Impacto
Não foi possível obter segunda opinião automática do Codex.

## Ação recomendada
- instalar um binário real do Codex no PATH, ou
- garantir que `npx` está disponível neste ambiente
MARKDOWN
  echo "Revisão Codex gravada em: $OUT_FILE"
  exit 0
fi

{
  echo "Faz uma revisão técnica paralela deste run."
  echo
  echo "Objetivos:"
  echo "- identificar falhas no plano"
  echo "- identificar riscos técnicos"
  echo "- identificar drift entre brief, plano e implementação"
  echo "- sugerir melhorias concretas"
  echo "- classificar resultado: aprovado / aprovado com reservas / rejeitado"
  echo
  echo "Modo de contexto: $MODE"
  echo "Se faltar contexto para uma conclusão forte, indica explicitamente qual artefacto precisa de leitura completa."
  echo
  echo "Responde em markdown estruturado com secções curtas."
  echo
  echo "## Run Snapshot"
  echo
  echo "- Diretório: ${RUN_DIR#$ROOT/}"
  echo "- Artefactos presentes:"
  find "$RUN_DIR" -maxdepth 1 -type f -printf '  - %f\n' | sort
  echo
  artifact_snapshot "Brief Snapshot" "$RUN_DIR/brief.md" 20
  artifact_snapshot "Pre-check Snapshot" "$RUN_DIR/pre-check.md" 20
  artifact_snapshot "Plan Snapshot" "$RUN_DIR/plan.md" 32
  artifact_snapshot "Build Snapshot" "$RUN_DIR/build-report.md" 32
  artifact_snapshot "QA Snapshot" "$RUN_DIR/qa-report.md" 32

  if [ "$MODE" = "full" ]; then
    echo "## Full Brief"
    echo
    [ -f "$RUN_DIR/brief.md" ] && cat "$RUN_DIR/brief.md"
    echo
    echo "## Full Pre-check"
    echo
    [ -f "$RUN_DIR/pre-check.md" ] && cat "$RUN_DIR/pre-check.md"
    echo
    echo "## Full Plan"
    echo
    [ -f "$RUN_DIR/plan.md" ] && cat "$RUN_DIR/plan.md"
    echo
    echo "## Full Build Report"
    echo
    [ -f "$RUN_DIR/build-report.md" ] && cat "$RUN_DIR/build-report.md"
    echo
    echo "## Full QA Report"
    echo
    [ -f "$RUN_DIR/qa-report.md" ] && cat "$RUN_DIR/qa-report.md"
  fi
} > "$TMP_PROMPT"

PROMPT="$(cat "$TMP_PROMPT")"

set +e
"${CODEX_CMD[@]}" exec \
  --cd "$ROOT" \
  --skip-git-repo-check \
  --color never \
  --json \
  "$PROMPT" > "$TMP_JSONL" 2> "$TMP_ERR"
CODEX_EXIT=$?
set -e

cp "$TMP_PROMPT" "$RUN_DIR/codex-review.prompt.txt"
cp "$TMP_JSONL" "$RUN_DIR/codex-review.raw.jsonl" 2>/dev/null || true
cp "$TMP_ERR" "$RUN_DIR/codex-review.stderr.log" 2>/dev/null || true

python3 - "$TMP_JSONL" "$OUT_FILE" "$CODEX_EXIT" "$TMP_ERR" <<'PY'
import json
import sys
from pathlib import Path

jsonl_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
exit_code = int(sys.argv[3])
err_path = Path(sys.argv[4])

chunks = []
errors = []

if jsonl_path.exists():
    for line in jsonl_path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            evt = json.loads(line)
        except json.JSONDecodeError:
            continue

        if evt.get("type") == "item.completed":
            item = evt.get("item", {})
            if item.get("type") == "message":
                for c in item.get("content", []):
                    if c.get("type") in ("output_text", "text"):
                        text = c.get("text", "").strip()
                        if text:
                            chunks.append(text)

        if evt.get("type") == "error":
            msg = evt.get("message", "").strip()
            if msg:
                errors.append(msg)

        if evt.get("type") == "turn.failed":
            err = evt.get("error", {})
            msg = err.get("message", "").strip()
            if msg:
                errors.append(msg)

stderr_text = err_path.read_text(errors="replace").strip() if err_path.exists() else ""

if chunks:
    out_path.write_text("\n\n".join(chunks).rstrip() + "\n")
    sys.exit(0)

message = ""
if errors:
    message = errors[0]
elif stderr_text:
    message = stderr_text
elif exit_code != 0:
    message = f"Codex terminou com código de saída {exit_code} sem texto utilizável."
else:
    message = "Codex não devolveu texto utilizável."

status = "rejeitado"
acao = "- verificar autenticação e limites de utilização do Codex"

if "usage limit" in message.lower() or "purchase more credits" in message.lower():
    status = "aprovado com reservas"
    acao = "- aguardar renovação da quota ou comprar mais créditos\n- repetir a revisão Codex quando houver saldo"

out = f"""# Codex Review

Estado: {status}

## Motivo
{message}

## Impacto
Não foi possível obter segunda opinião automática do Codex para este run.

## Ação recomendada
{acao}
"""

out_path.write_text(out)
PY

rm -f "$TMP_PROMPT" "$TMP_JSONL" "$TMP_ERR"

echo "Revisão Codex gravada em: $OUT_FILE"
