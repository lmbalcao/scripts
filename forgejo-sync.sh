#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/workspace/repos}"
FORGEJO_HOST="${FORGEJO_HOST:-forgejo.lbtec.org}"

# Lê a linha no formato: https://user:token@forgejo.lbtec.org
FORGEJO_AUTH_URL="$(grep -m1 -E "^https://[^/]+@${FORGEJO_HOST//./\\.}$" "$HOME/.git-credentials" || true)"
if [[ -z "${FORGEJO_AUTH_URL}" ]]; then
  echo "ERRO: não encontrei credenciais em ~/.git-credentials para ${FORGEJO_HOST}" >&2
  echo "Formato esperado: https://UTILIZADOR:TOKEN@${FORGEJO_HOST}" >&2
  exit 1
fi

# Extrair username do AUTH URL
FORGEJO_USER="$(echo "$FORGEJO_AUTH_URL" | sed -E 's#^https://([^:]+):.*#\1#')"

API_BASE="${FORGEJO_AUTH_URL}/api/v1"
CLONE_BASE="${FORGEJO_AUTH_URL}"  # clones via https://user:token@host/user/repo.git

# Dependências
command -v curl >/dev/null || { echo "ERRO: falta curl"; exit 1; }
command -v jq >/dev/null   || { echo "ERRO: falta jq"; exit 1; }
command -v git >/dev/null  || { echo "ERRO: falta git"; exit 1; }

api_get() {
  local path="$1"
  curl -fsS -H "Accept: application/json" "${API_BASE}${path}"
}

api_post_json() {
  local path="$1"
  local json="$2"
  curl -fsS -X POST \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$json" \
    "${API_BASE}${path}"
}

repo_exists_remote() {
  local owner="$1"
  local repo="$2"
  # 200 -> existe; 404 -> não existe
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" "${API_BASE}/repos/${owner}/${repo}")"
  [[ "$code" == "200" ]]
}

normalize_visibility_to_private_flag() {
  local v="$1"
  v="$(echo "$v" | tr -d '\r' | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$v" in
    public)  echo "false" ;;
    private) echo "true" ;;
    *) return 2 ;;
  esac
}

ensure_origin() {
  local dir="$1"
  local origin_url="$2"
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$dir" remote set-url origin "$origin_url"
  else
    git -C "$dir" remote add origin "$origin_url"
  fi
}

ensure_initial_branch() {
  local dir="$1"
  # Define main como branch padrão local (se ainda não existir)
  if git -C "$dir" rev-parse --verify main >/dev/null 2>&1; then
    git -C "$dir" checkout main >/dev/null 2>&1 || true
  else
    git -C "$dir" checkout -b main >/dev/null 2>&1 || true
  fi
}

push_all_if_needed() {
  local dir="$1"
  # Só faz commit/push se houver ficheiros (exclui .git) e alterações por commitar
  if [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 ! -name '.git' -print -quit 2>/dev/null)" ]]; then
    echo "[INFO] sem ficheiros para push: $(basename "$dir")"
    return 0
  fi

  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet; then
    echo "[INFO] nada para commitar: $(basename "$dir")"
  else
    git -C "$dir" commit -m "Initial sync" >/dev/null
    echo "[OK] commit criado: $(basename "$dir")"
  fi

  # Push para origin main (cria a branch remota)
  git -C "$dir" push -u origin main >/dev/null
  echo "[OK] push feito: $(basename "$dir")"
}

clone_missing_remote_repos() {
  echo "== A) Remoto -> Local: clonar o que falta =="
  mkdir -p "$WORKSPACE_DIR"

  # Lista de repos do user autenticado (inclui privados)
  local repos
  repos="$(api_get "/user/repos?limit=100&page=1" | jq -r '.[].name')"

  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    local target="${WORKSPACE_DIR}/${repo}"

    if [[ -d "$target/.git" ]]; then
      echo "[OK] já existe localmente (git): $repo"
      continue
    fi

    if [[ -e "$target" && ! -d "$target" ]]; then
      echo "[SKIP] existe mas não é diretório: $target"
      continue
    fi

    if [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
      echo "[SKIP] pasta existe e não é git (não vou sobrescrever): $repo"
      continue
    fi

    echo "[CLONE] $repo -> $target"
    git clone "${CLONE_BASE}/${FORGEJO_USER}/${repo}.git" "$target" >/dev/null
    echo "[OK] clonado: $repo"
  done <<< "$repos"
}

create_remote_from_local_markers() {
  echo "== B) Local -> Remoto: criar repos a partir de .repository =="
  mkdir -p "$WORKSPACE_DIR"

  shopt -s nullglob
  for dir in "$WORKSPACE_DIR"/*; do
    [[ -d "$dir" ]] || continue

    # Só atua se existir .repository
    [[ -f "$dir/.repository" ]] || continue

    local repo
    repo="$(basename "$dir")"

    local vis_raw private_flag
    vis_raw="$(cat "$dir/.repository" 2>/dev/null || true)"
    if ! private_flag="$(normalize_visibility_to_private_flag "$vis_raw")"; then
      echo "[ERRO] .repository inválido em $repo (usa 'public' ou 'private')"
      continue
    fi

    if repo_exists_remote "$FORGEJO_USER" "$repo"; then
      echo "[OK] já existe no Forgejo: ${FORGEJO_USER}/${repo}"
    else
      echo "[CRIAR] ${FORGEJO_USER}/${repo} (private=${private_flag})"
      api_post_json "/user/repos" "$(printf '{"name":"%s","private":%s}' "$repo" "$private_flag")" >/dev/null
      echo "[OK] criado no Forgejo: ${FORGEJO_USER}/${repo}"
    fi

    # Garantir repo git local e fazer push dos ficheiros
    if [[ ! -d "$dir/.git" ]]; then
      git -C "$dir" init >/dev/null
    fi

    ensure_initial_branch "$dir"
    ensure_origin "$dir" "${CLONE_BASE}/${FORGEJO_USER}/${repo}.git"
    push_all_if_needed "$dir"
  done
}

main() {
  echo "Forgejo host: ${FORGEJO_HOST}"
  echo "User: ${FORGEJO_USER}"
  echo "Workspace: ${WORKSPACE_DIR}"
  echo

  clone_missing_remote_repos
  echo
  create_remote_from_local_markers
}

main "$@"
