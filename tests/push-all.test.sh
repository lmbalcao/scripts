#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# PUSH_ALL_SH: caminho do push-all.sh a testar (por omissão o do repo);
# serve para apontar o teste a uma cópia mutada e provar que ele falha.
SCRIPT_PATH="${PUSH_ALL_SH:-${ROOT_DIR}/scripts/push-all.sh}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Todas as invocações usam BASE_DIR dentro de TMP_DIR e DRY_RUN=1, para que
# mesmo um script sem o bloco --help nunca toque em repos reais nem no remote.
EMPTY_DIR="${TMP_DIR}/empty"
mkdir -p "${EMPTY_DIR}"
export DRY_RUN=1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# ── 1. --help sai 0 ───────────────────────────────────────────────────────────
rc=0
help_out="$(BASE_DIR="${EMPTY_DIR}" bash "${SCRIPT_PATH}" --help 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 ]]; then
  fail "--help saiu ${rc}, esperado 0"
fi
echo "PASS: --help sai 0"

# ── 2. -h idêntico a --help ───────────────────────────────────────────────────
rc=0
short_out="$(BASE_DIR="${EMPTY_DIR}" bash "${SCRIPT_PATH}" -h 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 ]]; then
  fail "-h saiu ${rc}, esperado 0"
fi
if [[ "${short_out}" != "${help_out}" ]]; then
  fail "-h e --help produzem output diferente"
fi
echo "PASS: -h idêntico a --help"

# ── 3. a ajuda nomeia as 5 variáveis ──────────────────────────────────────────
for var in BASE_DIR REMOTE DRY_RUN SKIP_DIRTY SKIP_MIRROR; do
  if ! grep -q "${var}" <<<"${help_out}"; then
    fail "a ajuda não nomeia ${var}"
  fi
  echo "PASS: a ajuda nomeia ${var}"
done

# ── 4. BASE_DIR inexistente: --help não tenta entrar nele ─────────────────────
rc=0
missing_out="$(BASE_DIR="${TMP_DIR}/nao-existe" bash "${SCRIPT_PATH}" --help 2>&1)" || rc=$?
if grep -q "não consigo entrar em" <<<"${missing_out}"; then
  fail "--help com BASE_DIR inexistente emitiu 'não consigo entrar em'"
fi
echo "PASS: --help não emite 'não consigo entrar em' com BASE_DIR inexistente"

echo "OK"
