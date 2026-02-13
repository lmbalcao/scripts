#!/usr/bin/env bash
# repo-menu.sh
# Executar dentro de um repositório (ou pasta) em ~/workspace/repos/*
# Requer: bash, git, curl (e opcionalmente gh ou forgejo-cli/tea para criar repo remoto)
set -euo pipefail

# =========================
# CONFIG
# =========================
TEMPLATE_DIR="${TEMPLATE_DIR:-$HOME/workspace/repos/templates/repository}"
REQUIRED_FILES=( ".gitattributes" ".gitignore" ".prettierrc" "README.md" "VERSION" )

# Se quiseres forçar um remoto específico (ex.: forgejo):
#   export DEFAULT_REMOTE_URL_BASE="https://forgejo.lbtec.org"
DEFAULT_REMOTE_URL_BASE="${DEFAULT_REMOTE_URL_BASE:-}"

# =========================
# HELPERS
# =========================
die() { echo "[ERRO] $*" >&2; exit 1; }
warn() { echo "[AVISO] $*" >&2; }
info() { echo "[OK] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta comando: $1"
}

is_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

current_dir_name() {
  basename "$(repo_root)"
}

read_version_file() {
  local f
  f="$(repo_root)/VERSION"
  if [[ ! -f "$f" ]]; then
    echo "1.0.0"
    echo "private"
    echo "active"
    return 0
  fi

  # Lê 3 linhas, com defaults se estiver incompleto
  local v p s
  v="$(sed -n '1p' "$f" | tr -d '\r' | xargs || true)"
  p="$(sed -n '2p' "$f" | tr -d '\r' | xargs || true)"
  s="$(sed -n '3p' "$f" | tr -d '\r' | xargs || true)"

  [[ -n "${v:-}" ]] || v="1.0.0"
  [[ -n "${p:-}" ]] || p="private"
  [[ -n "${s:-}" ]] || s="active"

  echo "$v"
  echo "$p"
  echo "$s"
}

write_version_file() {
  local v="$1" p="$2" s="$3"
  local f
  f="$(repo_root)/VERSION"
  printf "%s\n%s\n%s\n" "$v" "$p" "$s" > "$f"
}

git_commit_if_needed() {
  local msg="$1"
  if ! is_git_repo; then
    die "Não é repo git (ainda). Usa a opção 1."
  fi

  if git diff --quiet && git diff --cached --quiet; then
    warn "Sem alterações para commit."
    return 0
  fi

  git add -A
  git commit -m "$msg"
}

git_push_if_possible() {
  if ! is_git_repo; then
    die "Não é repo git."
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    git push -u origin HEAD
    info "Push concluído."
  else
    warn "Sem remoto 'origin'. Configura/remoto via opção 1."
  fi
}

ensure_required_files() {
  local root
  root="$(repo_root)"

  [[ -d "$TEMPLATE_DIR" ]] || die "Template não existe: $TEMPLATE_DIR"

  local missing=0
  for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$root/$f" ]]; then
      warn "Falta: $f"
      missing=1
    fi
  done

  if [[ "$missing" -eq 0 ]]; then
    info "Ficheiros obrigatórios já existem."
    return 0
  fi

  for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$root/$f" ]]; then
      [[ -f "$TEMPLATE_DIR/$f" ]] || die "Template não tem $f em $TEMPLATE_DIR"
      cp -n "$TEMPLATE_DIR/$f" "$root/$f"
      info "Copiado (sem substituir): $f"
    fi
  done

  # Garantir defaults do VERSION se foi criado/copied vazio/incompleto
  local v p s
  IFS=$'\n' read -r v p s < <(read_version_file)
  write_version_file "$v" "$p" "$s"
  info "VERSION normalizado: $v / $p / $s"
}

increment_semver() {
  local ver="$1" bump="$2"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$ver"

  [[ "$major" =~ ^[0-9]+$ ]] || die "Versão inválida: $ver"
  [[ "$minor" =~ ^[0-9]+$ ]] || die "Versão inválida: $ver"
  [[ "$patch" =~ ^[0-9]+$ ]] || die "Versão inválida: $ver"

  case "$bump" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) die "Tipo de incremento inválido: $bump" ;;
  esac

  echo "${major}.${minor}.${patch}"
}

select_from_two() {
  local prompt="$1" a="$2" b="$3" current="$4"
  echo "$prompt (atual: $current)"
  echo "  1) $a"
  echo "  2) $b"
  read -r -p "Escolhe [1-2] (Enter = manter): " choice
  case "${choice:-}" in
    1) echo "$a" ;;
    2) echo "$b" ;;
    "") echo "$current" ;;
    *) die "Opção inválida." ;;
  esac
}

# =========================
# MENU ACTIONS
# =========================

action_1_init_git_and_remote() {
  require_cmd git

  local root
  root="$(repo_root)"
  cd "$root"

  ensure_required_files

  if is_git_repo; then
    warn "Já é um repositório git."
  else
    git init
    info "git init feito."
  fi

  # Commit inicial se necessário
  if ! git rev-parse HEAD >/dev/null 2>&1; then
    git add -A
    git commit -m "Initial commit"
    info "Commit inicial criado."
  fi

  # Configurar remoto + criar repo remoto
  # Aqui tens 3 caminhos (escolhe 1):
  # A) Via gh (GitHub)  -> gh repo create ...
  # B) Via tea (Forgejo/Gitea CLI) -> tea repo create ...
  # C) Manual: pedir URL e fazer git remote add origin URL

  echo
  echo "Criar remoto:"
  echo "  1) GitHub via gh (recomendado p/ GitHub)"
  echo "  2) Forgejo/Gitea via tea (se usares tea)"
  echo "  3) Manual (introduzir URL do remoto)"
  read -r -p "Escolhe [1-3]: " method

  local name owner url
  name="$(current_dir_name)"

  case "$method" in
    1)
      require_cmd gh
      # Privacidade vem do VERSION (private/public)
      local v p s
      IFS=$'\n' read -r v p s < <(read_version_file)
      local flag="--public"
      [[ "$p" == "private" ]] && flag="--private"

      # Cria repo e faz push
      gh repo create "$name" "$flag" --source="." --remote=origin --push
      info "Repo GitHub criado e push feito."
      ;;
    2)
      require_cmd tea
      # tea usa config local (host/token); cria repo no servidor autenticado
      # Privacidade: em Gitea/Forgejo, "private" é boolean.
      local v p s
      IFS=$'\n' read -r v p s < <(read_version_file)
      local private_flag="--private"
      [[ "$p" == "public" ]] && private_flag="--private=false"

      # Se quiseres forçar owner/org, exporta TEA_OWNER
      owner="${TEA_OWNER:-}"
      if [[ -n "$owner" ]]; then
        tea repo create --name "$name" --owner "$owner" $private_flag
        url="$(tea repo show --owner "$owner" "$name" --fields clone_url 2>/dev/null | awk 'NF{print $NF}' | tail -n1 || true)"
      else
        tea repo create --name "$name" $private_flag
        url="$(tea repo show "$name" --fields clone_url 2>/dev/null | awk 'NF{print $NF}' | tail -n1 || true)"
      fi

      if [[ -z "${url:-}" ]]; then
        warn "Não consegui obter clone_url via tea. Introduz manualmente o URL do remoto."
        read -r -p "URL do remoto (https/ssh): " url
      fi

      if git remote get-url origin >/dev/null 2>&1; then
        git remote set-url origin "$url"
      else
        git remote add origin "$url"
      fi
      git push -u origin HEAD
      info "Repo criado no Forgejo/Gitea e push feito."
      ;;
    3)
      read -r -p "URL do remoto (https/ssh): " url
      [[ -n "$url" ]] || die "URL vazio."
      if git remote get-url origin >/dev/null 2>&1; then
        git remote set-url origin "$url"
      else
        git remote add origin "$url"
      fi
      git push -u origin HEAD
      info "Remoto configurado e push feito."
      ;;
    *)
      die "Opção inválida."
      ;;
  esac
}

action_2_toggle_privacy() {
  require_cmd git
  ensure_required_files

  local v p s
  IFS=$'\n' read -r v p s < <(read_version_file)

  local new_p
  if [[ "$p" == "private" ]]; then new_p="public"; else new_p="private"; fi

  write_version_file "$v" "$new_p" "$s"
  info "Privacidade alterada: $p -> $new_p"

  if is_git_repo; then
    git_commit_if_needed "Change privacy to ${new_p}"
    git_push_if_possible
  else
    warn "Não é repo git. Usa a opção 1 para inicializar."
  fi

  # NOTA: isto só altera o ficheiro VERSION e faz push.
  # Para alterar a privacidade real no servidor (GitHub/Forgejo), precisas de gh/tea com API.
}

action_3_bump_version() {
  require_cmd git
  ensure_required_files

  local v p s
  IFS=$'\n' read -r v p s < <(read_version_file)

  echo "Versão atual: $v"
  echo "  1) Major"
  echo "  2) Minor"
  echo "  3) Patch"
  read -r -p "Escolhe [1-3] (Enter = cancelar): " choice

  local bump
  case "${choice:-}" in
    1) bump="major" ;;
    2) bump="minor" ;;
    3) bump="patch" ;;
    "") info "Cancelado."; return 0 ;;
    *) die "Opção inválida." ;;
  esac

  local new_v
  new_v="$(increment_semver "$v" "$bump")"

  read -r -p "Confirmar alteração ${v} -> ${new_v}? [s/N]: " ok
  case "${ok:-}" in
    s|S|sim|SIM) ;;
    *) info "Cancelado."; return 0 ;;
  esac

  write_version_file "$new_v" "$p" "$s"
  info "Versão atualizada: $new_v"

  if is_git_repo; then
    git_commit_if_needed "Bump version to ${new_v}"
    git_push_if_possible
  else
    warn "Não é repo git. Usa a opção 1 para inicializar."
  fi
}

action_4_toggle_state() {
  require_cmd git
  ensure_required_files

  local v p s
  IFS=$'\n' read -r v p s < <(read_version_file)

  local new_s
  if [[ "$s" == "active" ]]; then new_s="archived"; else new_s="active"; fi

  echo "Estado atual: $s"
  read -r -p "Alterar para ${new_s}? [s/N]: " ok
  case "${ok:-}" in
    s|S|sim|SIM) ;;
    *) info "Mantido."; return 0 ;;
  esac

  write_version_file "$v" "$p" "$new_s"
  info "Estado alterado: $s -> $new_s"

  if is_git_repo; then
    git_commit_if_needed "Change state to ${new_s}"
    git_push_if_possible
  else
    warn "Não é repo git. Usa a opção 1 para inicializar."
  fi

  # NOTA: isto só altera VERSION e faz push.
  # Arquivar de facto o repositório no servidor requer gh/tea.
}

action_5_ensure_files() {
  require_cmd git
  ensure_required_files

  if is_git_repo; then
    git_commit_if_needed "Ensure standard repository files"
    git_push_if_possible
  else
    warn "Não é repo git. Ficheiros foram garantidos localmente; usa a opção 1 para init/push."
  fi
}

show_status() {
  local v p s
  IFS=$'\n' read -r v p s < <(read_version_file)
  echo
  echo "Repo: $(repo_root)"
  echo "VERSION:"
  echo "  versão:      $v"
  echo "  privacidade: $p"
  echo "  estado:      $s"
  echo "Git: $(if is_git_repo; then echo "sim"; else echo "não"; fi)"
  if is_git_repo && git remote get-url origin >/dev/null 2>&1; then
    echo "Origin: $(git remote get-url origin)"
  else
    echo "Origin: (nenhum)"
  fi
  echo
}

main_menu() {
  while true; do
    show_status
    echo "Menu:"
    echo "  1) Gera Git (init + criar repo remoto + push)"
    echo "  2) Altera Privacidade (private/public) + commit + push"
    echo "  3) Altera Versão (major/minor/patch) + commit + push"
    echo "  4) Altera Estado (active/archived) + commit + push"
    echo "  5) Garante Ficheiros (copiar do template se faltar) + commit + push"
    echo "  0) Sair"
    read -r -p "Escolhe [0-5]: " opt

    case "${opt:-}" in
      1) action_1_init_git_and_remote ;;
      2) action_2_toggle_privacy ;;
      3) action_3_bump_version ;;
      4) action_4_toggle_state ;;
      5) action_5_ensure_files ;;
      0) exit 0 ;;
      *) warn "Opção inválida." ;;
    esac
  done
}

# =========================
# ENTRY
# =========================
main_menu
