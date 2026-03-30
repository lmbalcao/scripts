#!/usr/bin/env bash
# dev-install.sh — Deploy terraform + terraform-gui stack to a new Proxmox LXC CT
#
# Usage (from Proxmox host):
#
#   export GIT_URL=https://forgejo.lbtec.org
#   export GIT_USER=lmbalcao
#   export GIT_PASSWORD=<token>              # opcional, para repos privados
#   export PROXMOX_API_URL=https://proxmox.local:8006/api2/json
#   export PROXMOX_API_TOKEN_ID=terraform@pve!token
#   export PROXMOX_API_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
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

# ── Terraform credentials (required) ─────────────────────────────────────────

PROXMOX_API_URL="${PROXMOX_API_URL:-}"
PROXMOX_API_TOKEN_ID="${PROXMOX_API_TOKEN_ID:-}"
PROXMOX_API_TOKEN="${PROXMOX_API_TOKEN:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# ── Pre-flight ────────────────────────────────────────────────────────────────

[[ "${EUID}" -eq 0 || "${DEV_INSTALL_SKIP_ROOT_CHECK:-0}" == "1" ]] || die "Executa como root."

for cmd in pct pvesh pvesm pveam awk sed grep ip head tr hostname; do
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

storage_exists() { pvesm status --storage "$1" >/dev/null 2>&1; }

discover_storage_rootfs() {
  [[ -n "${PROXMOX_STORAGE}" ]] && { echo "${PROXMOX_STORAGE}"; return; }
  storage_exists "local-lvm" && { echo "local-lvm"; return; }
  echo "local"
}

discover_storage_templates() {
  [[ -n "${PROXMOX_STORAGE_TEMPLATES}" ]] && { echo "${PROXMOX_STORAGE_TEMPLATES}"; return; }
  echo "local"
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

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  local node bridge storage_root storage_tpl template net0

  node="$(discover_node)"
  bridge="$(discover_bridge)"
  storage_root="$(discover_storage_rootfs)"
  storage_tpl="$(discover_storage_templates)"
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

  # ── Step 1: Create CT ──────────────────────────────────────────────────────

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

  # ── Step 2: System packages ────────────────────────────────────────────────

  log_info "Instalar pacotes de sistema..."
  ct_exec "apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg lsb-release git"

  # ── Step 3: Docker ────────────────────────────────────────────────────────

  log_info "Instalar Docker..."
  ct_exec "install -m 0755 -d /etc/apt/keyrings"
  ct_exec "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  ct_exec "chmod a+r /etc/apt/keyrings/docker.gpg"
  ct_exec 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
  ct_exec "apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  ct_exec "systemctl enable docker && systemctl start docker"

  # ── Step 4: Directories ───────────────────────────────────────────────────

  log_info "Criar directorias..."
  ct_exec "mkdir -p /opt/terraform/data /opt/terraform/plugin-cache /opt/terraform/config"
  ct_exec "mkdir -p /opt/terraform-gui"
  ct_exec "mkdir -p /opt/data/logs"
  ct_exec "mkdir -p /mnt/data"

  # ── Step 5: Clone repos ───────────────────────────────────────────────────

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

  # ── Step 6: Deploy docker configs ────────────────────────────────────────

  log_info "Copiar ficheiros docker..."
  ct_exec "cp /tmp/docker-repo/terraform/docker-compose.yml /opt/terraform/docker-compose.yml"
  ct_exec "cp /tmp/docker-repo/terraform/Dockerfile         /opt/terraform/Dockerfile"
  ct_exec "cp /tmp/docker-repo/terraform/Dockerfile.api     /opt/terraform/Dockerfile.api"
  ct_exec "cp /tmp/docker-repo/terraform-gui/docker-compose.yml /opt/terraform-gui/docker-compose.yml"
  ct_exec "cp /opt/terraform-gui/workspace/nginx.conf /opt/terraform-gui/nginx.conf"

  # ── Step 7: Credentials ───────────────────────────────────────────────────

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

  # ── Step 8: Start containers ──────────────────────────────────────────────

  log_info "Criar network terraform-net..."
  ct_exec "docker network create terraform-net 2>/dev/null || true"

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
    log_warn "terraform-api não respondeu em 60s. Verifica: docker compose -f /opt/terraform/docker-compose.yml logs"
  fi

  log_info "Arrancar terraform-gui..."
  ct_exec "cd /opt/terraform-gui && docker compose up -d"

  # ── Step 9: Final check ───────────────────────────────────────────────────

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
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Diagnóstico:                                        ║"
    echo "║    pct exec <VMID> -- docker compose \\              ║"
    echo "║      -f /opt/terraform/docker-compose.yml logs       ║"
    echo "╚══════════════════════════════════════════════════════╝"
  fi
}

main "$@"
