#!/usr/bin/env bash
# dev-install.sh — Deploy terraform + terraform-gui stack to a new Proxmox LXC CT
#
# Usage (from Proxmox host):
#
#   export GIT_URL=https://forgejo.lbtec.org
#   export GIT_USER=lmbalcao
#   export GIT_PASSWORD=<token>              # opcional, para repos privados
#   export PROXMOX_API_URL=https://proxmox.local:8006/api2/json   # opcional, auto-descoberto
#   export PROXMOX_API_TOKEN_ID=terraform@pve!terraform           # opcional, criado automaticamente
#   export PROXMOX_API_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx # opcional, criado automaticamente
#   bash dev-install.sh
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()        { log_error "$*"; exit 1; }
need_cmd()   { command -v "$1" >/dev/null 2>&1 || die "Falta o comando: $1"; }

# ── Git / repo config ─────────────────────────────────────────────────────────

GIT_URL="${GIT_URL:-https://forgejo.lbtec.org}"
GIT_USER="${GIT_USER:-lmbalcao}"
GIT_BRANCH="${GIT_BRANCH:-master}"
GIT_PASSWORD="${GIT_PASSWORD:-}"

GIT_TERRAFORM_REPO="${GIT_TERRAFORM_REPO:-${GIT_URL}/${GIT_USER}/terraform.git}"
GIT_DOCKER_REPO="${GIT_DOCKER_REPO:-${GIT_URL}/${GIT_USER}/docker.git}"
GIT_GUI_REPO="${GIT_GUI_REPO:-${GIT_URL}/${GIT_USER}/terraform-gui.git}"

# ── CT config ─────────────────────────────────────────────────────────────────

HOSTNAME_CT="${HOSTNAME_CT:-terraform}"

TERRAFORM_VLAN="${VLAN:-${TERRAFORM_VLAN:-35}}"
TERRAFORM_IP="${TERRAFORM_IP:-}"                        # empty = DHCP
TERRAFORM_GATEWAY="${TERRAFORM_GATEWAY:-}"
TERRAFORM_NAMESERVER="${DNS_SERVER:-${TERRAFORM_NAMESERVER:-}}"
TERRAFORM_SEARCHDOMAIN="${DNS_DOMAIN:-${TERRAFORM_SEARCHDOMAIN:-}}"
TERRAFORM_VMID="${TERRAFORM_VMID:-}"

TERRAFORM_CORES="${STACK_CORES:-${TERRAFORM_CORES:-2}}"
TERRAFORM_RAM="${STACK_RAM:-${TERRAFORM_RAM:-2048}}"
TERRAFORM_SWAP="${STACK_SWAP:-${TERRAFORM_SWAP:-512}}"
TERRAFORM_DISK_GB="${STACK_DISK_GB:-${TERRAFORM_DISK_GB:-10}}"

PROXMOX_NODE="${PROXMOX_NODE:-}"
PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-}"
PROXMOX_STORAGE_TEMPLATES="${PROXMOX_STORAGE_TEMPLATES:-}"
PROXMOX_TEMPLATE="${PROXMOX_TEMPLATE:-}"

# ── Terraform credentials ─────────────────────────────────────────────────────
# If not provided, the script creates terraform@pve user + token automatically.

PROXMOX_API_URL="${PROXMOX_API_URL:-}"
PROXMOX_API_TOKEN_ID="${PROXMOX_API_TOKEN_ID:-}"
PROXMOX_API_TOKEN="${PROXMOX_API_TOKEN:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# ── Proxmox terraform user constants ─────────────────────────────────────────

_PVE_TF_USER="terraform@pve"
_PVE_TF_ROLE="TerraformRole"
_PVE_TF_TOKEN_NAME="terraform"
_PVE_TF_PRIVS="Datastore.AllocateSpace,Datastore.Audit,Pool.Allocate,Pool.Audit,SDN.Use,Sys.Audit,Sys.Console,Sys.Modify,VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Migrate,VM.PowerMgmt"

# ── Pre-flight ────────────────────────────────────────────────────────────────

[[ "${EUID}" -eq 0 || "${DEV_INSTALL_SKIP_ROOT_CHECK:-0}" == "1" ]] || die "Executa como root."

for cmd in pct pvesh pvesm pveam pveum python3 awk sed grep ip head tr hostname; do
  need_cmd "$cmd"
done

# ── Discovery helpers ─────────────────────────────────────────────────────────

discover_node() {
  [[ -n "${PROXMOX_NODE}" ]] && { echo "${PROXMOX_NODE}"; return; }
  hostname -s
}

discover_bridge() {
  [[ -n "${PROXMOX_BRIDGE}" ]] && { echo "${PROXMOX_BRIDGE}"; return; }
  echo "vmbr0"
}

# List storages on <node> that support <content_type> (rootdir | vztmpl | images …)
node_storages_with_content() {
  local node="$1" content_type="$2"
  pvesh get "/nodes/${node}/storage" --output-format json 2>/dev/null \
    | python3 -c "
import json, sys
ct = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for s in data:
    if ct in s.get('content', '').split(',') and s.get('active', 0):
        print(s['storage'])
" "${content_type}"
}

# Validate that a manually specified storage supports <content_type> on <node>
_validate_storage_content() {
  local node="$1" storage="$2" content_type="$3"
  local result
  result="$(pvesh get "/nodes/${node}/storage" --output-format json 2>/dev/null \
    | python3 -c "
import json, sys
storage = sys.argv[1]
ct = sys.argv[2]
try:
    data = json.load(sys.stdin)
except Exception:
    print('parse_error')
    sys.exit(0)
for s in data:
    if s.get('storage') == storage:
        if not s.get('active', 0):
            print('not_active')
        elif ct not in s.get('content', '').split(','):
            print('wrong_content')
        else:
            print('ok')
        sys.exit(0)
print('not_found')
" "${storage}" "${content_type}")"
  case "${result}" in
    ok)            return 0 ;;
    not_active)    die "Storage '${storage}' não está activo no node '${node}'." ;;
    wrong_content) die "Storage '${storage}' não suporta '${content_type}' no node '${node}'." ;;
    not_found)     die "Storage '${storage}' não encontrado no node '${node}'." ;;
    *)             die "Erro ao verificar storage '${storage}' no node '${node}'." ;;
  esac
}

discover_storage_rootfs() {
  local node="$1"
  if [[ -n "${PROXMOX_STORAGE}" ]]; then
    _validate_storage_content "${node}" "${PROXMOX_STORAGE}" "rootdir"
    echo "${PROXMOX_STORAGE}"
    return
  fi
  local candidates
  candidates="$(node_storages_with_content "${node}" "rootdir")"
  [[ -z "${candidates}" ]] && die "Nenhum storage com suporte a 'rootdir' encontrado no node '${node}'."
  for preferred in "local-lvm" "local"; do
    if echo "${candidates}" | grep -qx "${preferred}"; then
      echo "${preferred}"; return
    fi
  done
  echo "${candidates}" | head -1
}

discover_storage_templates() {
  local node="$1"
  if [[ -n "${PROXMOX_STORAGE_TEMPLATES}" ]]; then
    _validate_storage_content "${node}" "${PROXMOX_STORAGE_TEMPLATES}" "vztmpl"
    echo "${PROXMOX_STORAGE_TEMPLATES}"
    return
  fi
  local candidates
  candidates="$(node_storages_with_content "${node}" "vztmpl")"
  [[ -z "${candidates}" ]] && die "Nenhum storage com suporte a 'vztmpl' encontrado no node '${node}'."
  for preferred in "local" "local-lvm"; do
    if echo "${candidates}" | grep -qx "${preferred}"; then
      echo "${preferred}"; return
    fi
  done
  echo "${candidates}" | head -1
}

discover_template() {
  [[ -n "${PROXMOX_TEMPLATE}" ]] && { echo "${PROXMOX_TEMPLATE}"; return; }
  pveam available --section system \
    | awk '{print $2}' \
    | grep debian-12-standard \
    | sort -V \
    | tail -n1
}

ensure_template_downloaded() {
  local storage="$1" template="$2"
  pveam list "$storage" | awk '{print $1}' | grep -qx "$template" && return
  pveam download "$storage" "$template"
}

next_vmid() {
  [[ -n "${TERRAFORM_VMID}" ]] && echo "${TERRAFORM_VMID}" || pvesh get /cluster/nextid
}

gen_password() {
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24
}

build_net0() {
  local bridge="$1"
  local net0=""
  if [[ -z "${TERRAFORM_IP}" ]]; then
    net0="name=eth0,bridge=${bridge},ip=dhcp"
  else
    net0="name=eth0,bridge=${bridge},ip=${TERRAFORM_IP},gw=${TERRAFORM_GATEWAY}"
  fi
  if [[ -n "${TERRAFORM_VLAN}" ]]; then
    [[ "${TERRAFORM_VLAN}" =~ ^[0-9]+$ ]] || die "VLAN invalida: ${TERRAFORM_VLAN}"
    net0="${net0},tag=${TERRAFORM_VLAN}"
  fi
  echo "${net0}"
}

get_ct_ip() {
  pct exec "$1" -- hostname -I 2>/dev/null | awk '{print $1}' || true
}

inject_git_credentials() {
  local url="$1"
  if [[ -n "${GIT_PASSWORD}" ]]; then
    echo "${url/https:\/\//https:\/\/${GIT_USER}:${GIT_PASSWORD}@}"
  else
    echo "$url"
  fi
}

ct_exec() {
  pct exec "$VMID" -- bash -c "$1"
}

# ── Proxmox token creation ────────────────────────────────────────────────────
# Creates terraform@pve user, TerraformRole, and API token if credentials are
# not already provided via environment variables.
# Sets PROXMOX_API_URL, PROXMOX_API_TOKEN_ID, PROXMOX_API_TOKEN on success.

ensure_proxmox_terraform_token() {
  if [[ -n "${PROXMOX_API_URL}" && -n "${PROXMOX_API_TOKEN_ID}" && -n "${PROXMOX_API_TOKEN}" ]]; then
    log_info "Credenciais Proxmox já definidas."
    return
  fi

  if [[ -z "${PROXMOX_API_URL}" ]]; then
    local node_ip
    node_ip="$(hostname -I | awk '{print $1}')"
    PROXMOX_API_URL="https://${node_ip}:8006/api2/json"
    log_info "PROXMOX_API_URL auto-descoberto: ${PROXMOX_API_URL}"
  fi

  log_info "A criar utilizador Terraform no Proxmox (${_PVE_TF_USER})..."

  pveum user add "${_PVE_TF_USER}" --comment "Terraform GUI" 2>/dev/null \
    && log_info "Utilizador ${_PVE_TF_USER} criado." \
    || log_info "Utilizador ${_PVE_TF_USER} já existe."

  if pveum role add "${_PVE_TF_ROLE}" --privs "${_PVE_TF_PRIVS}" 2>/dev/null; then
    log_info "Role ${_PVE_TF_ROLE} criada."
  else
    pveum role modify "${_PVE_TF_ROLE}" --privs "${_PVE_TF_PRIVS}" 2>/dev/null || true
    log_info "Role ${_PVE_TF_ROLE} já existe (privileges actualizados)."
  fi

  pveum aclmod / --user "${_PVE_TF_USER}" --role "${_PVE_TF_ROLE}" 2>/dev/null || true
  log_info "ACL configurada: / → ${_PVE_TF_USER}:${_PVE_TF_ROLE}"

  local token_json
  if token_json="$(pveum user token add "${_PVE_TF_USER}" "${_PVE_TF_TOKEN_NAME}" \
        --expire 0 --privsep 0 --output-format json 2>/dev/null)"; then
    PROXMOX_API_TOKEN="$(printf '%s' "${token_json}" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('value',''))")"
    PROXMOX_API_TOKEN_ID="${_PVE_TF_USER}!${_PVE_TF_TOKEN_NAME}"
    log_info "Token API ${PROXMOX_API_TOKEN_ID} criado."
  else
    if [[ -n "${PROXMOX_API_TOKEN_ID}" && -n "${PROXMOX_API_TOKEN}" ]]; then
      log_info "Token já existe; a usar PROXMOX_API_TOKEN_ID/TOKEN fornecidos."
    else
      log_warn "Token '${_PVE_TF_TOKEN_NAME}' já existe para ${_PVE_TF_USER} e o secret não é recuperável."
      log_warn "Para recriar:"
      log_warn "  pveum user token remove ${_PVE_TF_USER} ${_PVE_TF_TOKEN_NAME}"
      log_warn "  pveum user token add ${_PVE_TF_USER} ${_PVE_TF_TOKEN_NAME} --expire 0 --privsep 0"
      die "Define PROXMOX_API_TOKEN_ID e PROXMOX_API_TOKEN manualmente e volta a correr."
    fi
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  local node bridge storage_root storage_tpl template net0

  node="$(discover_node)"
  bridge="$(discover_bridge)"
  storage_root="$(discover_storage_rootfs "${node}")"
  storage_tpl="$(discover_storage_templates "${node}")"
  template="$(discover_template)"

  [[ -n "$template" ]] || die "Nenhum template Debian 12 encontrado. Descarrega primeiro com pveam."

  ensure_template_downloaded "$storage_tpl" "$template"
  ip link show "$bridge" >/dev/null 2>&1 || die "Bridge ${bridge} não existe"

  VMID="$(next_vmid)"
  net0="$(build_net0 "$bridge")"

  # Auto-generate root password if not provided
  if [[ -z "${ROOT_PASSWORD}" ]]; then
    ROOT_PASSWORD="$(gen_password)"
    log_warn "ROOT_PASSWORD não definido — gerado automaticamente: ${ROOT_PASSWORD}"
  fi

  # ── Step 1: Proxmox token ──────────────────────────────────────────────────

  ensure_proxmox_terraform_token

  # ── Step 2: Create CT ──────────────────────────────────────────────────────

  log_info "Criar CT ${VMID} (${HOSTNAME_CT})..."
  pct create "$VMID" "${storage_tpl}:vztmpl/${template}" \
    --hostname "$HOSTNAME_CT" \
    --cores "$TERRAFORM_CORES" \
    --memory "$TERRAFORM_RAM" \
    --swap "$TERRAFORM_SWAP" \
    --rootfs "${storage_root}:${TERRAFORM_DISK_GB}" \
    --net0 "$net0" \
    --unprivileged 1 \
    --features nesting=1 \
    --password "$ROOT_PASSWORD"

  [[ -n "${TERRAFORM_NAMESERVER}" ]]   && pct set "$VMID" --nameserver "$TERRAFORM_NAMESERVER"
  [[ -n "${TERRAFORM_SEARCHDOMAIN}" ]] && pct set "$VMID" --searchdomain "$TERRAFORM_SEARCHDOMAIN"

  pct start "$VMID"
  log_info "Aguardar boot..."
  sleep 8

  # ── Step 3: System packages ────────────────────────────────────────────────

  log_info "Instalar pacotes de sistema..."
  ct_exec "apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg lsb-release git"

  # ── Step 4: Docker ────────────────────────────────────────────────────────

  log_info "Instalar Docker..."
  ct_exec "install -m 0755 -d /etc/apt/keyrings"
  ct_exec "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  ct_exec "chmod a+r /etc/apt/keyrings/docker.gpg"
  ct_exec 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
  ct_exec "apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  ct_exec "systemctl enable docker && systemctl start docker"

  # ── Step 5: Directories ───────────────────────────────────────────────────

  log_info "Criar directorias..."
  ct_exec "mkdir -p /opt/terraform/data /opt/terraform/plugin-cache /opt/terraform/config"
  ct_exec "mkdir -p /opt/terraform-gui"
  ct_exec "mkdir -p /opt/data/logs"
  ct_exec "mkdir -p /mnt/data"

  # Minimal .terraformrc — prevents "Unable to open CLI configuration file" warning
  ct_exec "touch /opt/terraform/config/.terraformrc"

  # ── Step 6: Clone repos ───────────────────────────────────────────────────

  local tf_url docker_url gui_url
  tf_url="$(inject_git_credentials "$GIT_TERRAFORM_REPO")"
  docker_url="$(inject_git_credentials "$GIT_DOCKER_REPO")"
  gui_url="$(inject_git_credentials "$GIT_GUI_REPO")"

  log_info "Clonar repo terraform → /opt/terraform/workspace ..."
  ct_exec "git clone '${tf_url}' /opt/terraform/workspace"

  log_info "Clonar repo docker → /tmp/docker-repo ..."
  ct_exec "git clone '${docker_url}' /tmp/docker-repo"

  log_info "Clonar repo terraform-gui → /opt/terraform-gui/workspace ..."
  ct_exec "git clone '${gui_url}' /opt/terraform-gui/workspace"

  # ── Step 7: Deploy docker configs ────────────────────────────────────────

  log_info "Copiar ficheiros docker..."
  ct_exec "cp /tmp/docker-repo/terraform/docker-compose.yml /opt/terraform/docker-compose.yml"
  ct_exec "cp /tmp/docker-repo/terraform/Dockerfile         /opt/terraform/Dockerfile"
  ct_exec "cp /tmp/docker-repo/terraform/Dockerfile.api     /opt/terraform/Dockerfile.api"
  ct_exec "cp /tmp/docker-repo/terraform-gui/docker-compose.yml /opt/terraform-gui/docker-compose.yml"
  ct_exec "cp /opt/terraform-gui/workspace/nginx.conf /opt/terraform-gui/nginx.conf"

  # ── Step 8: Credentials ───────────────────────────────────────────────────

  log_info "Escrever credenciais Terraform..."
  ct_exec "mkdir -p /opt/terraform/workspace/env/${ENVIRONMENT}"

  pct exec "$VMID" -- bash -c "cat > /opt/terraform/workspace/env/${ENVIRONMENT}/proxmox-base.tfvars <<'TFEOF'
proxmox_api_url      = \"${PROXMOX_API_URL}\"
proxmox_api_token_id = \"${PROXMOX_API_TOKEN_ID}\"
proxmox_api_token    = \"${PROXMOX_API_TOKEN}\"
proxmox_tls_insecure = true
root_password        = \"${ROOT_PASSWORD}\"
TFEOF"

  # common.tfvars (skip if already exists in repo)
  pct exec "$VMID" -- bash -c "
    if [[ ! -f /opt/terraform/workspace/env/${ENVIRONMENT}/common.tfvars ]]; then
      cat > /opt/terraform/workspace/env/${ENVIRONMENT}/common.tfvars <<'COMMON_EOF'
environment    = \"${ENVIRONMENT}\"
inventory_root = \"../../inventory\"
COMMON_EOF
    fi
  "

  # ── Step 9: Start containers ──────────────────────────────────────────────

  log_info "Build + arrancar containers terraform (pode demorar alguns minutos)..."
  ct_exec "cd /opt/terraform && docker compose build --pull"
  ct_exec "cd /opt/terraform && docker compose up -d"

  log_info "Aguardar terraform-api..."
  local _retries=0
  until ct_exec "curl -sf http://localhost:8765/api/health > /dev/null 2>&1" || (( _retries++ >= 20 )); do
    sleep 3
  done

  if ct_exec "curl -sf http://localhost:8765/api/health > /dev/null 2>&1"; then
    log_info "terraform-api OK."
  else
    log_warn "terraform-api não respondeu em 60s — logs:"
    pct exec "$VMID" -- bash -c "
      echo '--- container status ---'
      docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep -E 'NAMES|terraform'
      echo '--- terraform-api logs (last 30) ---'
      docker logs terraform-api --tail 30 2>&1 || echo '(container nao existe)'
    " || true
  fi

  log_info "Arrancar terraform-gui..."
  ct_exec "cd /opt/terraform-gui && docker compose up -d"

  # ── Step 10: Final check ──────────────────────────────────────────────────

  sleep 5
  local ip
  ip="$(get_ct_ip "$VMID")"

  echo ""
  if ct_exec "curl -sf http://localhost:80/api/health > /dev/null 2>&1"; then
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  Terraform GUI instalado com sucesso!                ║"
    echo "╠══════════════════════════════════════════════════════╣"
    printf "║  URL:        http://%-32s║\n" "${ip}/"
    printf "║  CT VMID:    %-38s║\n" "${VMID}"
    printf "║  Ambiente:   %-38s║\n" "${ENVIRONMENT}"
    printf "║  Root pass:  %-38s║\n" "${ROOT_PASSWORD}"
    echo "╚══════════════════════════════════════════════════════╝"
  else
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  AVISO: health check falhou                          ║"
    echo "╠══════════════════════════════════════════════════════╣"
    printf "║  CT VMID: %-42s║\n" "${VMID}"
    printf "║  IP:      %-42s║\n" "${ip}"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    echo "--- container status ---"
    pct exec "$VMID" -- bash -c "docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep -E 'NAMES|terraform'" || true
    echo ""
    echo "--- terraform-api logs ---"
    pct exec "$VMID" -- bash -c "docker logs terraform-api --tail 40 2>&1 || echo '(container nao existe)'" || true
    echo ""
    echo "--- terraform-gui logs ---"
    pct exec "$VMID" -- bash -c "docker logs terraform-gui --tail 10 2>&1 || echo '(container nao existe)'" || true
  fi
}

main "$@"
