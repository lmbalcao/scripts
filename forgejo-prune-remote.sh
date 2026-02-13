#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/workspace/repos}"
FORGEJO_HOST="${FORGEJO_HOST:-forgejo.lbtec.org}"
DRY_RUN="${DRY_RUN:-0}"   # 1 = só mostrar | 0 = apagar mesmo

# Credenciais
FORGEJO_AUTH_URL="$(grep -m1 -E "^https://[^/]+@${FORGEJO_HOST//./\\.}$" "$HOME/.git-credentials" || true)"
if [[ -z "$FORGEJO_AUTH_URL" ]]; then
  echo "ERRO: credenciais não encontradas em ~/.git-credentials para ${FORGEJO_HOST}" >&2
  exit 1
fi

FORGEJO_USER="$(echo "$FORGEJO_AUTH_URL" | sed -E 's#^https://([^:]+):.*#\1#')"
API_BASE="${FORGEJO_AUTH_URL}/api/v1"

command -v curl >/dev/null || { echo "ERRO: falta curl"; exit 1; }
command -v jq   >/dev/null || { echo "ERRO: falta jq"; exit 1; }

api_get() {
  curl -fsS -H "Accept: application/json" "${API_BASE}$1"
}

api_delete() {
  curl -fsS -X DELETE -H "Accept: application/json" "${API_BASE}$1"
}

echo "Forgejo host : $FORGEJO_HOST"
echo "Utilizador   : $FORGEJO_USER"
echo "Workspace    : $WORKSPACE_DIR"
echo "DRY_RUN      : $DRY_RUN"
echo

repos="$(api_get "/user/repos?limit=200" | jq -r '.[].name')"

confirm_delete() {
  local repo="$1"
  while true; do
    read -r -p "Apagar no Forgejo o repositório '${repo}'? [y/N] " ans
    case "$ans" in
      [yY]|[yY][eE][sS]) return 0 ;;
      ""|[nN]|[nN][oO])  return 1 ;;
      *) echo "Responde y ou n." ;;
    esac
  done
}


for repo in $repos; do
  local_path="${WORKSPACE_DIR}/${repo}"

  if [[ -d "$local_path" ]]; then
    echo "[OK] existe localmente: $repo"
    continue
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
  echo "[DRY-RUN] seria apagado no Forgejo: $FORGEJO_USER/$repo"
  else
  if confirm_delete "$FORGEJO_USER/$repo"; then
    echo "[DELETE] a apagar no Forgejo: $FORGEJO_USER/$repo"
    api_delete "/repos/${FORGEJO_USER}/${repo}"
    echo "[OK] apagado: $repo"
  else
    echo "[SKIP] mantido no Forgejo: $repo"
  fi
  fi
  
done
