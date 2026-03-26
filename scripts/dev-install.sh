#!/bin/bash
set -euo pipefail
#export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Falta o comando: $1"; }

# ============================================================
# VARS
# ============================================================

GIT_URL=${GIT_URL:-"https://forgejo.lbtec.org"}
# GIT_USER: utilizador/organização no servidor Git. Obrigatório se o repositório não for público.
GIT_USER=${GIT_USER:-lmbalcao}
GIT_BRANCH=${GIT_BRANCH:-main}

HOSTNAME_CT="${HOSTNAME_CT:-dev-terraform}"
TERRAFORM_VLAN="${VLAN:-${TERRAFORM_VLAN:-99}}"
TERRAFORM_IP="${TERRAFORM_IP:-192.168.99.201/24}"
TERRAFORM_GATEWAY="${TERRAFORM_GATEWAY:-192.168.99.1}"
TERRAFORM_NAMESERVER="${TERRAFORM_NAMESERVER:-192.168.99.1}"
TERRAFORM_VMID="${TERRAFORM_VMID:-}"
TERRAFORM_CORES="${STACK_CORES:-${TERRAFORM_CORES:-4}}"
TERRAFORM_RAM="${STACK_RAM:-${TERRAFORM_RAM:-8096}}"
TERRAFORM_SWAP="${STACK_SWAP:-${TERRAFORM_SWAP:-1024}}"
TERRAFORM_DISK_GB="${STACK_DISK_GB:-${TERRAFORM_DISK_GB:-5}}"

PROXMOX_NODE="${PROXMOX_NODE:-}"
PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-}"
PROXMOX_STORAGE_TEMPLATES="${PROXMOX_STORAGE_TEMPLATES:-}"
PROXMOX_TEMPLATE="${PROXMOX_TEMPLATE:-}"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-}"
TERRAFORM_INJECT_SSH_KEY_ALL_NODES="${TERRAFORM_INJECT_SSH_KEY_ALL_NODES:-1}"

[[ "${EUID}" -eq 0 ]] || die "Executa como root."
for cmd in pct pvesh pvesm pveam pveum awk sed grep ip sha256sum head tr; do need_cmd "$cmd"; done
for cmd in qm; do need_cmd "$cmd"; done

discover_node() {
  [[ -n "${PROXMOX_NODE}" ]] && echo "${PROXMOX_NODE}" && return
  local hn; hn="$(hostname -s 2>/dev/null || true)"
  [[ -n "${hn}" ]] && pvesh get "/nodes/${hn}" >/dev/null 2>&1 && echo "${hn}" && return
  pvesh get /nodes --output-format json | awk -F\" '/"node":/ {print $4; exit}'
}

discover_bridge() {
  [[ -n "${PROXMOX_BRIDGE}" ]] && echo "${PROXMOX_BRIDGE}" && return
  grep -qE '^\s*auto\s+vmbr0\b|^\s*iface\s+vmbr0\b' /etc/network/interfaces 2>/dev/null && echo "vmbr0" && return
  local b; b="$(awk '/^\s*iface\s+vmbr[0-9]+/ {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)"
  [[ -n "${b}" ]] && echo "${b}" && return
  ip -o link show | awk -F': ' '$2 ~ /^vmbr[0-9]+$/ {print $2; exit}'
}

storage_has_content() { pvesm status --storage "$1" >/dev/null 2>&1; }

discover_storage_rootfs() {
  [[ -n "${PROXMOX_STORAGE}" ]] && echo "${PROXMOX_STORAGE}" && return
  storage_has_content "local-lvm" && echo "local-lvm" && return
  storage_has_content "local" && echo "local" && return
  pvesm status | awk 'NR>1 {print $1; exit}'
}

discover_storage_templates() {
  [[ -n "${PROXMOX_STORAGE_TEMPLATES}" ]] && echo "${PROXMOX_STORAGE_TEMPLATES}" && return
  storage_has_content "local" && echo "local" && return
  pvesm status | awk 'NR==2 {print $1}'
}

discover_template() {
  [[ -n "${PROXMOX_TEMPLATE}" ]] && echo "${PROXMOX_TEMPLATE}" && return
  local t; t="$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-12-standard_.*_amd64\.tar\.zst$' | sort -V | tail -n1)"
  [[ -n "${t}" ]] || die "Não encontrei template Debian 12."
  echo "${t}"
}

ensure_template_downloaded() {
  pveam list "$1" 2>/dev/null | awk '{print $1}' | grep -qx "$2" && log_info "Template já existe: $2" && return
  log_info "A transferir template: $2"
  pveam download "$1" "$2"
}

next_vmid() {
  [[ -n "${TERRAFORM_VMID}" ]] && echo "${TERRAFORM_VMID}" && return
  pvesh get /cluster/nextid
}

gen_password() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true; }

trim_value() {
  local v="${1:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "${v}"
}

is_positive_int() {
  local v
  v="$(trim_value "${1:-}")"
  [[ "${v}" =~ ^[0-9]+$ ]] && [[ "${v}" -gt 0 ]]
}

normalize_optional_numeric() {
  local current="$1"
  local fallback="$2"
  local val
  val="$(trim_value "${current}")"
  if is_positive_int "${val}"; then
    printf '%s' "${val}"
    return 0
  fi
  printf '%s' "${fallback}"
}

ensure_install_defaults() {

  GIT_URL="$(trim_value "${GIT_URL}")"
  GIT_USER="$(trim_value "${GIT_USER}")"
  GIT_BRANCH="$(trim_value "${GIT_BRANCH}")"
  GIT_REPO="$(trim_value "${GIT_REPO}")"

  TERRAFORM_IP="$(trim_value "${TERRAFORM_IP}")"
  TERRAFORM_GATEWAY="$(trim_value "${TERRAFORM_GATEWAY}")"
  TERRAFORM_NAMESERVER="$(trim_value "${TERRAFORM_NAMESERVER}")"
  TERRAFORM_VMID="$(trim_value "${TERRAFORM_VMID}")"
  TERRAFORM_VLAN="$(trim_value "${TERRAFORM_VLAN}")"

  TERRAFORM_CORES="$(normalize_optional_numeric "${TERRAFORM_CORES}" "4")"
  TERRAFORM_RAM="$(normalize_optional_numeric "${TERRAFORM_RAM}" "8096")"
  TERRAFORM_SWAP="$(normalize_optional_numeric "${TERRAFORM_SWAP}" "1024")"
  TERRAFORM_DISK_GB="$(normalize_optional_numeric "${TERRAFORM_DISK_GB}" "10")"
  POSTGRES_PORT="$(normalize_optional_numeric "${POSTGRES_PORT}" "5432")"

  if [[ -n "${TERRAFORM_VLAN}" ]] && ! [[ "${TERRAFORM_VLAN}" =~ ^[0-9]+$ ]]; then
    log_warn "VLAN inválida ('${TERRAFORM_VLAN}'); a ignorar tag VLAN."
    TERRAFORM_VLAN=""
  fi

  if [[ -n "${TERRAFORM_VMID}" ]] && ! [[ "${TERRAFORM_VMID}" =~ ^[0-9]+$ ]]; then
    log_warn "VMID inválido ('${TERRAFORM_VMID}'); a usar próximo VMID automático."
    TERRAFORM_VMID=""
  fi

  if [[ -n "${TERRAFORM_IP}" ]] && [[ "${TERRAFORM_IP}" != */* ]]; then
    log_warn "IP estático sem CIDR ('${TERRAFORM_IP}'); a usar DHCP."
    TERRAFORM_IP=""
    TERRAFORM_GATEWAY=""
    TERRAFORM_NAMESERVER=""
  fi
}

validate_static_network_config() {
  local ip_cidr="$1"
  local gateway="$2"
  local nameserver="$3"

  if ! command -v python3 >/dev/null 2>&1; then
    log_warn "python3 não encontrado; validação avançada de rede estática foi ignorada."
    return 0
  fi

  python3 - "${ip_cidr}" "${gateway}" "${nameserver}" <<'PY'
import ipaddress
import sys

ip_cidr = (sys.argv[1] or "").strip()
gateway = (sys.argv[2] or "").strip()
nameserver = (sys.argv[3] or "").strip()

try:
    iface = ipaddress.ip_interface(ip_cidr)
except Exception:
    print(f"IP estático inválido: {ip_cidr}", file=sys.stderr)
    raise SystemExit(1)

try:
    gw = ipaddress.ip_address(gateway)
except Exception:
    print(f"Gateway inválido: {gateway}", file=sys.stderr)
    raise SystemExit(1)

if gw.version != iface.ip.version:
    print("Gateway e IP têm versões diferentes (IPv4/IPv6).", file=sys.stderr)
    raise SystemExit(1)

if gw not in iface.network:
    print(
        f"Gateway {gateway} fora da subnet {iface.network} do IP {ip_cidr}.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if gw == iface.ip:
    print("IP estático não pode ser igual ao gateway.", file=sys.stderr)
    raise SystemExit(1)

if nameserver:
    try:
        ns = ipaddress.ip_address(nameserver)
    except Exception:
        print(f"Nameserver inválido: {nameserver}", file=sys.stderr)
        raise SystemExit(1)
    if ns.version != iface.ip.version:
        print("Nameserver e IP têm versões diferentes (IPv4/IPv6).", file=sys.stderr)
        raise SystemExit(1)

if not iface.ip.is_private:
    print(
        f"AVISO: IP {iface.ip} não está em faixa privada (confirma se é intencional).",
        file=sys.stderr,
    )
PY
}

setup_ct_ssh_key_and_authorize_on_host() {
  local vmid="$1"
  log_info "A configurar chave SSH do CT e autorizar no host Proxmox..."

  # Gera chave SSH no CT (se não existir)
  pct exec "${vmid}" -- bash -lc '
    set -e
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if [ ! -f /root/.ssh/id_ed25519 ]; then
      ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -C "stackctl-ct" >/dev/null
    fi
    chmod 600 /root/.ssh/id_ed25519
    chmod 644 /root/.ssh/id_ed25519.pub
  '

  CT_SSH_PUBKEY="$(pct exec "${vmid}" -- bash -lc 'cat /root/.ssh/id_ed25519.pub' | tr -d '\r')"
  [[ -n "${CT_SSH_PUBKEY}" ]] || die "Falha ao obter chave pública SSH do CT."

  # Autoriza no host Proxmox que executa o installer
  install -d -m 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  if ! grep -qxF "${CT_SSH_PUBKEY}" /root/.ssh/authorized_keys; then
    echo "${CT_SSH_PUBKEY}" >> /root/.ssh/authorized_keys
    log_info "Chave pública do CT adicionada em /root/.ssh/authorized_keys do host."
  else
    log_info "Chave pública do CT já autorizada no host."
  fi

  # Opcional (desejado): propagar para todos os nodes Proxmox do cluster
  if [[ "${TERRAFORM_INJECT_SSH_KEY_ALL_NODES}" =~ ^(1|true|yes|on)$ ]]; then
    local local_node cluster_nodes n node_ip
    local_node="$(hostname -s 2>/dev/null || true)"
    # Best effort: nunca falhar a instalação inteira por causa desta propagação opcional.
    cluster_nodes="$(
      pvesh get /nodes --output-format json 2>/dev/null \
        | tr -d '\n' \
        | grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)"$/\1/' \
        || true
    )"
    if [[ -z "${cluster_nodes}" ]]; then
      log_warn "Não foi possível listar nodes do cluster para propagar chave SSH (ignorado)."
      return 0
    fi
    for n in ${cluster_nodes}; do
      [[ -z "${n}" || "${n}" == "${local_node}" ]] && continue
      node_ip="$(getent ahostsv4 "${n}" 2>/dev/null | awk 'NR==1{print $1}' || true)"
      if [[ -z "${node_ip}" ]]; then
        log_warn "Node ${n} sem IP resolvível (ignorado)."
        continue
      fi
      if ssh \
        -o BatchMode=yes \
        -o NumberOfPasswordPrompts=0 \
        -o ConnectTimeout=5 \
        -o ConnectionAttempts=1 \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=1 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "root@${node_ip}" \
        "install -d -m 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && grep -qxF '${CT_SSH_PUBKEY}' /root/.ssh/authorized_keys || echo '${CT_SSH_PUBKEY}' >> /root/.ssh/authorized_keys" \
        >/dev/null 2>&1; then
        log_info "Chave pública propagada para node ${n} (${node_ip})."
      else
        log_warn "Não foi possível propagar chave para node ${n} (${node_ip}) (ignorado)."
      fi
    done
  fi
}

_PVE_TF_USER="terraform@pve"
_PVE_TF_ROLE="TerraformRole"
_PVE_TF_TOKEN_NAME="terraform-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8 || true)"
_PVE_TF_PRIVS="Datastore.AllocateSpace,Datastore.Audit,Pool.Allocate,Pool.Audit,SDN.Use,Sys.Audit,Sys.Console,Sys.Modify,VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Migrate,VM.PowerMgmt"

# Creates terraform@pve user, TerraformRole, and API token.
# Sets global tf_token_value="" on success; warns and leaves it empty if token already exists.
create_proxmox_terraform_user_token() {
  log_info "A criar utilizador Terraform no Proxmox (${_PVE_TF_USER})..."

  # Utilizador (idempotente)
  pveum user add "${_PVE_TF_USER}" --comment "Terraform Terraform" 2>/dev/null \
    && log_info "Utilizador ${_PVE_TF_USER} criado." \
    || log_info "Utilizador ${_PVE_TF_USER} já existe."

  # Role (idempotente: cria ou actualiza privileges)
  if pveum role add "${_PVE_TF_ROLE}" --privs "${_PVE_TF_PRIVS}" 2>/dev/null; then
    log_info "Role ${_PVE_TF_ROLE} criada."
  else
    pveum role modify "${_PVE_TF_ROLE}" --privs "${_PVE_TF_PRIVS}" 2>/dev/null || true
    log_info "Role ${_PVE_TF_ROLE} já existe (privileges actualizados)."
  fi

  # ACL / → terraform@pve:TerraformRole
  pveum aclmod / --user "${_PVE_TF_USER}" --role "${_PVE_TF_ROLE}" 2>/dev/null || true
  log_info "ACL configurada: / → ${_PVE_TF_USER}:${_PVE_TF_ROLE}"

  # Token API (idempotente: avisa se já existe — o secret só é visível no momento da criação)
  local token_json
  if token_json="$(pveum user token add "${_PVE_TF_USER}" "${_PVE_TF_TOKEN_NAME}" \
        --expire 0 --privsep 0 --output-format json 2>/dev/null)"; then
    tf_token_value="$(printf '%s' "${token_json}" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')"
    log_info "Token API ${_PVE_TF_USER}!${_PVE_TF_TOKEN_NAME} criado."
  else
    tf_token_value=""
    log_warn "Token '${_PVE_TF_TOKEN_NAME}' já existe para ${_PVE_TF_USER}."
    log_warn "  O secret não é recuperável. Para recriar:"
    log_warn "  pveum user token remove ${_PVE_TF_USER} ${_PVE_TF_TOKEN_NAME}"
    log_warn "  pveum user token add ${_PVE_TF_USER} ${_PVE_TF_TOKEN_NAME} --expire 0 --privsep 0"
  fi
}

discover_gateway() { ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'; }
discover_nameserver() { awk '/^nameserver / {print $2; exit}' /etc/resolv.conf 2>/dev/null; }

build_net0() {
  local bridge="$1" vlan="${2:-}" ipconf=""
  if [[ -z "${TERRAFORM_IP}" ]]; then
    ipconf="ip=dhcp"
  else
    [[ "${TERRAFORM_IP}" == */* ]] || die "TERRAFORM_IP tem de incluir CIDR."
    local gw="${TERRAFORM_GATEWAY:-}"; [[ -n "${gw}" ]] || gw="$(discover_gateway)"; [[ -n "${gw}" ]] || die "Gateway não encontrado."
    local ns="${TERRAFORM_NAMESERVER:-}"; [[ -n "${ns}" ]] || ns="$(discover_nameserver)"; [[ -n "${ns}" ]] || die "Nameserver não encontrado."
    validate_static_network_config "${TERRAFORM_IP}" "${gw}" "${ns}" || die "Configuração de rede estática inválida."
    ipconf="ip=${TERRAFORM_IP},gw=${gw}"
    TERRAFORM_NAMESERVER="${ns}"; TERRAFORM_GATEWAY="${gw}"
  fi
  local base="name=eth0,bridge=${bridge},${ipconf}"
  [[ -n "${vlan}" ]] && { [[ "${vlan}" =~ ^[0-9]+$ ]] || die "VLAN inválida"; base="${base},tag=${vlan}"; }
  echo "${base}"
}

# ============================================================
# INTERACTIVE SETUP
# ============================================================

prompt_settings() {
  echo
  log_info "Terraform Installer - Configuração"
  echo
  echo "Escolhe modo de instalação:"
  echo "  1) Default (recomendado)"
  echo "  2) Custom"
  echo
  read -p "Opção [1]: " mode < /dev/tty
  mode="$(trim_value "${mode:-1}")"
  [[ -n "${mode}" ]] || mode="1"
  
  if [[ "${mode}" != "2" ]]; then
    log_info "A usar configurações default."
    return
  fi
  
  log_info "Modo custom - pressiona ENTER para usar default"
  echo
  
  read -p "VLAN [vazio=sem VLAN]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_VLAN="${input}"
  
  read -p "IP estático com CIDR (ex: 192.168.1.50/24) [vazio=DHCP]: " input < /dev/tty
  input="$(trim_value "${input}")"
  if [[ -n "${input}" ]]; then
    TERRAFORM_IP="${input}"
    
    read -p "Gateway [vazio=auto-detect]: " input < /dev/tty
    input="$(trim_value "${input}")"
    [[ -n "${input}" ]] && TERRAFORM_GATEWAY="${input}"
    
    read -p "Nameserver [vazio=auto-detect]: " input < /dev/tty
    input="$(trim_value "${input}")"
    [[ -n "${input}" ]] && TERRAFORM_NAMESERVER="${input}"
  fi
  
  read -p "VMID [vazio=auto]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_VMID="${input}"
  
  read -p "CPU cores [${TERRAFORM_CORES}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_CORES="${input}"
  
  read -p "RAM em MB [${TERRAFORM_RAM}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_RAM="${input}"
  
  read -p "SWAP em MB [${TERRAFORM_SWAP}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_SWAP="${input}"
  
  read -p "Disco em GB [${TERRAFORM_DISK_GB}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_DISK_GB="${input}"
  
  echo
  log_info "Configuração custom aplicada."
}

# Forçar interatividade via /dev/tty (funciona com pipe)
if [[ -c /dev/tty ]]; then
  prompt_settings < /dev/tty
else
  log_info "Modo não-interativo detectado - a usar defaults."
fi

ensure_install_defaults

# ============================================================
# EXECUTE
# ============================================================

main() {
  local node bridge storage_root storage_tpl template vmid net0 ct_root_pw tf_token_value proxmox_api_url
  
  node="$(discover_node)"; [[ -n "${node}" ]] || die "PROXMOX_NODE não encontrado."
  bridge="$(discover_bridge)"; [[ -n "${bridge}" ]] || die "PROXMOX_BRIDGE não encontrado."
  storage_root="$(discover_storage_rootfs)"; [[ -n "${storage_root}" ]] || die "PROXMOX_STORAGE não encontrado."
  storage_tpl="$(discover_storage_templates)"; [[ -n "${storage_tpl}" ]] || die "PROXMOX_STORAGE_TEMPLATES não encontrado."
  template="$(discover_template)"
  ensure_template_downloaded "${storage_tpl}" "${template}"
  ensure_vm_cloudinit_template "${node}" "${bridge}" "${storage_tpl}"
  vmid="$(next_vmid)"; [[ -n "${vmid}" ]] || die "VMID falhou."
  net0="$(build_net0 "${bridge}" "${TERRAFORM_VLAN}")"

  log_info "Configuração:"
  echo "  NODE=${node} BRIDGE=${bridge} STORAGE=${storage_root} TEMPLATE=${template}"
  echo "  VMID=${vmid} HOSTNAME=${HOSTNAME_CT} NET=${net0}"
  echo "  CORES=${TERRAFORM_CORES} RAM=${TERRAFORM_RAM}MB SWAP=${TERRAFORM_SWAP}MB DISK=${TERRAFORM_DISK_GB}GB"
  echo

  ct_root_pw="$(gen_password)"
  
  log_info "A criar CT ${vmid}..."
  pct create "${vmid}" "${storage_tpl}:vztmpl/${template}" \
    --hostname "${HOSTNAME_CT}" \
    --ostype debian \
    --cores "${TERRAFORM_CORES}" \
    --memory "${TERRAFORM_RAM}" \
    --swap "${TERRAFORM_SWAP}" \
    --rootfs "${storage_root}:${TERRAFORM_DISK_GB}" \
    --net0 "${net0}" \
    --unprivileged 1 \
    --features "nesting=1" \
    --onboot 1 \
    --password "${ct_root_pw}"

  [[ -n "${TERRAFORM_IP}" && -n "${TERRAFORM_NAMESERVER}" ]] && pct set "${vmid}" --nameserver "${TERRAFORM_NAMESERVER}"

  log_info "CT criado com sucesso."
  
# ============================================================
# SETUP DO CT
# ============================================================

  log_info "A iniciar Setup do CT..."
  pct start "${vmid}"
  sleep 5

  log_info "A executar preflight de rede, updates, instalar requisitos e preparar /opt/terraform..."
  pct exec "${vmid}" -- env \
    EXPECTED_GW="${TERRAFORM_GATEWAY}" \
    EXPECT_STATIC_IP="${TERRAFORM_IP}" \
    TERRAFORM_COMPOSE_RAW_URL="https://forgejo.lbtec.org/lmbalcao/docker/raw/branch/master/terraform/docker-compose.yml" \
    bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive

      echo "[INFO] Preflight de rede no CT..."
      ip -4 addr show dev eth0 || true
      ip -4 route show || true

      if [ -n "${EXPECT_STATIC_IP}" ]; then
        if ! ip -4 route show default | grep -q "^default via "; then
          echo "[ERROR] Sem rota default no CT (modo IP estático)."
          exit 1
        fi

        if [ -n "${EXPECTED_GW}" ]; then
          if command -v ping >/dev/null 2>&1; then
            ping -c1 -W2 "${EXPECTED_GW}" >/dev/null 2>&1 || {
              echo "[ERROR] Gateway ${EXPECTED_GW} não responde a partir do CT."
              exit 1
            }
          fi
        fi
      fi

      if ! getent hosts deb.debian.org >/dev/null 2>&1; then
        echo "[ERROR] DNS falhou no CT (deb.debian.org não resolvido)."
        cat /etc/resolv.conf || true
        exit 1
      fi

      if ! timeout 6 bash -lc "cat </dev/null >/dev/tcp/deb.debian.org/80" >/dev/null 2>&1; then
        echo "[ERROR] Sem conectividade TCP para deb.debian.org:80 (rede/VLAN/gateway/firewall)."
        exit 1
      fi

      apt-get -o Acquire::Retries=3 update
      apt-get -o Acquire::Retries=3 upgrade -y
      apt-get install -y curl wget git ca-certificates gnupg lsb-release openssh-client rsync util-linux

      apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg

      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

      mkdir -p /opt/terraform

      if [ -z "${TERRAFORM_COMPOSE_RAW_URL:-}" ]; then
        echo "[ERROR] Variável TERRAFORM_COMPOSE_RAW_URL não definida."
        exit 1
      fi

      echo "[INFO] A descarregar docker-compose.yml para /opt/terraform..."
      curl -fL "${TERRAFORM_COMPOSE_RAW_URL}" -o /opt/terraform/docker-compose.yml

      test -s /opt/terraform/docker-compose.yml || {
        echo "[ERROR] O ficheiro /opt/terraform/docker-compose.yml ficou vazio."
        exit 1
      }

      echo "[INFO] Ficheiro colocado em /opt/terraform/docker-compose.yml"
      ls -l /opt/terraform/docker-compose.yml
    '

  log_info "Setup do CT concluído."

  # Preparar SSH CT -> host Proxmox (para passos pós-deploy via SSH)
  setup_ct_ssh_key_and_authorize_on_host "${vmid}"

# ============================================================
# DEPLOY DE CONFIG FILES
# ============================================================

  echo
  echo "════════════════════════════════════════════════"
  echo " Terraform — Instalação concluída"
  echo "════════════════════════════════════════════════"
  echo " CT_VMID                = ${vmid}"
  echo " CT_ROOT_PASSWORD       = ${ct_root_pw}"
  echo " CT_IP                  = ${ct_ip}"
  echo "────────────────────────────────────────────────"
  echo " PROXMOX_API_URL        = ${proxmox_api_url}"
  echo " PROXMOX_TF_USER        = ${_PVE_TF_USER}!${_PVE_TF_TOKEN_NAME}"
  echo " PROXMOX_TF_TOKEN       = ${tf_token_value:-'(token já existia — ver Vault: infra/proxmox.token_value)'}"
  echo "════════════════════════════════════════════════"

  log_warn "SEGURANÇA: O ficheiro /opt/lazyterra/.env no CT contém estas credenciais em texto simples."
  log_warn "Guarda-as num gestor de passwords e APAGA o ficheiro:"
  log_warn "  pct exec ${vmid} -- rm -f /opt/lazyterra/.env"
  log_info "Guarda estas credenciais — não serão mostradas novamente."
}

main "$@"
