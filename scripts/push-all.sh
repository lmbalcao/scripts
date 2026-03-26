#!/usr/bin/env bash
set -u  # sem -e para não parar a meio
set -o pipefail

BASE_DIR="${BASE_DIR:-$HOME/workspace/repos}"
REMOTE="${REMOTE:-origin}"
DRY_RUN="${DRY_RUN:-0}"          # 1 = só mostrar, 0 = executar
SKIP_DIRTY="${SKIP_DIRTY:-1}"    # 1 = ignora repos com alterações por commitar
SKIP_MIRROR="${SKIP_MIRROR:-1}"  # 1 = ignora mirror read-only

cd "$BASE_DIR" || { echo "ERRO: não consigo entrar em $BASE_DIR"; exit 1; }

ok=0; skipped=0; err=0

for d in */; do
  repo="${d%/}"

  if [[ ! -d "$repo/.git" ]]; then
    echo "SKIP (não é git): $repo"
    ((skipped++))
    continue
  fi

  echo "==> $repo"
  (
    cd "$repo" || exit 1

    if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
      echo "  SKIP (sem remote '$REMOTE')"
      exit 10
    fi

    branch="$(git symbolic-ref --short -q HEAD || true)"
    if [[ -z "$branch" ]]; then
      echo "  SKIP (DETACHED HEAD)"
      exit 10
    fi

    if [[ "$SKIP_DIRTY" == "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
      echo "  SKIP (working tree suja)"
      exit 10
    fi

    git fetch "$REMOTE" --prune >/dev/null 2>&1 || true

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "  DRY_RUN: git push --force-with-lease $REMOTE $branch"
      exit 0
    fi

    out="$(git push --force-with-lease "$REMOTE" "$branch" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "$out"
      exit 0
    fi

    if [[ "$SKIP_MIRROR" == "1" ]] && grep -qi "mirror repository is read-only" <<<"$out"; then
      echo "  SKIP (mirror read-only)"
      exit 10
    fi

    echo "$out" >&2
    exit 1
  )
  rc=$?

  if [[ $rc -eq 0 ]]; then
    ((ok++))
  elif [[ $rc -eq 10 ]]; then
    ((skipped++))
  else
    echo "  ERRO: $repo"
    ((err++))
  fi
done

echo
echo "Resumo: OK=$ok  SKIP=$skipped  ERRO=$err"
