#!/usr/bin/env bash
# dev-install.sh — Deploy terraform + terraform-gui stack to a new Proxmox LXC CT
#
# Usage (from Proxmox host):
#
#   export GIT_URL=https://forgejo.lbtec.org
#   export GIT_USER=lmbalcao
#   export GIT_PASSWORD=<token>              # opcional, para repos privados
#   export PROXMOX_API_URL=https://proxmox.local:8006/api2/json   # opcional, auto-descoberto
#   export PROXMOX_ROOT_PASSWORD=<root@pam-password>              # obrigatório (ou introduzir quando pedido)
#   bash dev-install.sh
#
set -euo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Falhou na linha $LINENO: $BASH_COMMAND" >&2' ERR

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
# The provider authenticates as root@pam with password.
# root@pam is required for bind-mount operations in LXC containers.

PROXMOX_API_URL="${PROXMOX_API_URL:-}"
PROXMOX_ROOT_PASSWORD="${PROXMOX_ROOT_PASSWORD:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

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

# ── Cluster helpers ───────────────────────────────────────────────────────────

discover_cluster_nodes() {
  pvesh get /nodes --output-format json 2>/dev/null \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for n in data:
        print(n['node'])
except Exception:
    pass
"
}

inject_ssh_key_to_nodes() {
  local pubkey="$1"
  local local_node
  local_node="$(hostname -s)"

  while IFS= read -r node; do
    [[ -z "$node" ]] && continue
    log_info "Injectar chave SSH no node: ${node}"
    if [[ "$node" == "$local_node" ]]; then
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh
      grep -qxF "$pubkey" /root/.ssh/authorized_keys 2>/dev/null \
        || printf '%s\n' "$pubkey" >> /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
    else
      ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
          "root@${node}" /bin/sh -s -- "$pubkey" <<'REMOTE' \
        || log_warn "Falhou injecção no node ${node} — verifica SSH cluster."
set -eu
pubkey="$1"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
grep -qxF "$pubkey" /root/.ssh/authorized_keys 2>/dev/null \
  || printf '%s\n' "$pubkey" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
REMOTE
    fi
  done <<< "$(discover_cluster_nodes)"
}

# ── Proxmox credentials ───────────────────────────────────────────────────────

ensure_proxmox_credentials() {
  if [[ -z "${PROXMOX_API_URL}" ]]; then
    local node_ip
    node_ip="$(hostname -I | awk '{print $1}')"
    PROXMOX_API_URL="https://${node_ip}:8006/api2/json"
    log_info "PROXMOX_API_URL auto-descoberto: ${PROXMOX_API_URL}"
  fi

  if [[ -z "${PROXMOX_ROOT_PASSWORD}" ]]; then
    read -r -s -p "Introduz a password root@pam do Proxmox: " PROXMOX_ROOT_PASSWORD < /dev/tty
    echo
    [[ -n "${PROXMOX_ROOT_PASSWORD}" ]] || die "PROXMOX_ROOT_PASSWORD não pode ser vazio."
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

  # ── Step 1: Proxmox credentials ───────────────────────────────────────────

  ensure_proxmox_credentials

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
  log_info "Aguardar boot do CT..."
  local _boot_retries=0
  until pct exec "$VMID" -- true 2>/dev/null || (( _boot_retries++ >= 15 )); do
    sleep 2
  done
  pct exec "$VMID" -- true || die "CT ${VMID} não respondeu após 30s."

  # ── Step 3: System packages ────────────────────────────────────────────────

  log_info "Instalar pacotes de sistema..."
  ct_exec "DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 apt-get update -qq"
  ct_exec "DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 apt-get install -y -qq ca-certificates curl gnupg lsb-release git locales"
  ct_exec "locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8 || true"

  # ── Step 4: Docker ────────────────────────────────────────────────────────

  log_info "Instalar Docker..."
  ct_exec "install -m 0755 -d /etc/apt/keyrings"
  ct_exec "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  ct_exec "chmod a+r /etc/apt/keyrings/docker.gpg"
  ct_exec 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
  ct_exec "DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  ct_exec "systemctl enable docker"
  ct_exec "systemctl start docker || true"
  local _docker_retries=0
  until ct_exec "docker info >/dev/null 2>&1" || (( _docker_retries++ >= 10 )); do
    log_info "Aguardar Docker arrancar..."
    sleep 3
  done
  ct_exec "docker info >/dev/null 2>&1" || log_warn "Docker pode não estar pronto — continuando."

  # ── Step 5: Directories ───────────────────────────────────────────────────

  log_info "Criar directorias..."
  ct_exec "mkdir -p /opt/terraform/data /opt/terraform/plugin-cache /opt/terraform/config"
  ct_exec "mkdir -p /opt/terraform-gui"
  ct_exec "mkdir -p /opt/data/logs"
  ct_exec "mkdir -p /mnt/data"

  # Minimal .terraformrc — prevents "Unable to open CLI configuration file" warning
  ct_exec "touch /opt/terraform/config/.terraformrc"

  # ── Step 6: SSH keypair ───────────────────────────────────────────────────

  log_info "Gerar par de chaves SSH no CT..."
  ct_exec "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
  ct_exec "[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C 'terraform@${HOSTNAME_CT}'"
  # Copiar chave para /opt/terraform/config — montado em /terraform/config dentro do Docker
  ct_exec "cp /root/.ssh/id_ed25519 /opt/terraform/config/id_ed25519 && chmod 600 /opt/terraform/config/id_ed25519"
  CT_PUBKEY="$(pct exec "$VMID" -- cat /root/.ssh/id_ed25519.pub)"
  log_info "Chave pública: ${CT_PUBKEY}"

  inject_ssh_key_to_nodes "$CT_PUBKEY"

  # ── Step 8: Clone repos ───────────────────────────────────────────────────

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

  # ── Step 9: Deploy docker configs ────────────────────────────────────────

  log_info "Copiar ficheiros docker..."
  log_info "Conteúdo de /tmp/docker-repo:"
  ct_exec "ls /tmp/docker-repo/ && ls /tmp/docker-repo/terraform/ && ls /tmp/docker-repo/terraform-gui/ 2>/dev/null || true"

  log_info "cp terraform/docker-compose.yml..."
  ct_exec "cp /tmp/docker-repo/terraform/docker-compose.yml /opt/terraform/docker-compose.yml"
  log_info "cp terraform/Dockerfile..."
  ct_exec "cp /tmp/docker-repo/terraform/Dockerfile /opt/terraform/Dockerfile"
  log_info "cp terraform/Dockerfile.api..."
  ct_exec "cp /tmp/docker-repo/terraform/Dockerfile.api /opt/terraform/Dockerfile.api"
  log_info "cp terraform-gui/docker-compose.yml..."
  ct_exec "cp /tmp/docker-repo/terraform-gui/docker-compose.yml /opt/terraform-gui/docker-compose.yml"
  log_info "cp terraform-gui/nginx.conf..."
  ct_exec "cp /opt/terraform-gui/workspace/nginx.conf /opt/terraform-gui/nginx.conf"

  # ── Step 10: Credentials ─────────────────────────────────────────────────

  log_info "Escrever credenciais Terraform..."
  ct_exec "mkdir -p /opt/terraform/workspace/env/${ENVIRONMENT}"

  pct exec "$VMID" -- bash -c "cat > /opt/terraform/workspace/env/${ENVIRONMENT}/proxmox-base.tfvars <<'TFEOF'
proxmox_api_url              = \"${PROXMOX_API_URL}\"
proxmox_password             = \"${PROXMOX_ROOT_PASSWORD}\"
proxmox_tls_insecure         = true
root_password                = \"${ROOT_PASSWORD}\"
proxmox_ssh_private_key_path = \"/terraform/config/id_ed25519\"
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

  # ── Step 11: Start containers ────────────────────────────────────────────

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

  # ── Step 12: Final check ─────────────────────────────────────────────────

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
