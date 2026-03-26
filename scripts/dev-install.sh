#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Falta o comando: $1"; }

GIT_URL="${GIT_URL:-https://forgejo.lbtec.org}"
GIT_USER="${GIT_USER:-lmbalcao}"
GIT_REPO="${GIT_REPO:-docker}"
GIT_BRANCH="${GIT_BRANCH:-master}"

HOSTNAME_CT="${HOSTNAME_CT:-dev-terraform}"

TERRAFORM_VLAN="${VLAN:-${TERRAFORM_VLAN:-}}"
TERRAFORM_IP="${TERRAFORM_IP:-192.168.99.201/24}"
TERRAFORM_GATEWAY="${TERRAFORM_GATEWAY:-192.168.99.1}"
TERRAFORM_NAMESERVER="${TERRAFORM_NAMESERVER:-192.168.99.1}"
TERRAFORM_VMID="${TERRAFORM_VMID:-}"

TERRAFORM_CORES="${STACK_CORES:-${TERRAFORM_CORES:-1}}"
TERRAFORM_RAM="${STACK_RAM:-${TERRAFORM_RAM:-1024}}"
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

for cmd in pct pvesh pvesm pveam pveum awk sed grep ip sha256sum head tr qm ssh getent hostname; do
  need_cmd "$cmd"
done

discover_node() {
  [[ -n "${PROXMOX_NODE}" ]] && { echo "${PROXMOX_NODE}"; return; }

  local hn
  hn="$(hostname -s 2>/dev/null || true)"
  [[ -n "${hn}" ]] && pvesh get "/nodes/${hn}" >/dev/null 2>&1 && { echo "${hn}"; return; }

  pvesh get /nodes --output-format json | awk -F'"' '/"node":/ {print $4; exit}'
}

discover_bridge() {
  [[ -n "${PROXMOX_BRIDGE}" ]] && { echo "${PROXMOX_BRIDGE}"; return; }

  grep -qE '^[[:space:]]*auto[[:space:]]+vmbr0\b|^[[:space:]]*iface[[:space:]]+vmbr0\b' /etc/network/interfaces 2>/dev/null && {
    echo "vmbr0"
    return
  }

  local b
  b="$(awk '/^[[:space:]]*iface[[:space:]]+vmbr[0-9]+/ {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)"
  [[ -n "${b}" ]] && { echo "${b}"; return; }

  ip -o link show | awk -F': ' '$2 ~ /^vmbr[0-9]+$/ {print $2; exit}'
}

storage_exists() {
  pvesm status --storage "$1" >/dev/null 2>&1
}

discover_storage_rootfs() {
  [[ -n "${PROXMOX_STORAGE}" ]] && { echo "${PROXMOX_STORAGE}"; return; }

  storage_exists "local-lvm" && { echo "local-lvm"; return; }
  storage_exists "local" && { echo "local"; return; }

  pvesm status | awk 'NR>1 {print $1; exit}'
}

discover_storage_templates() {
  [[ -n "${PROXMOX_STORAGE_TEMPLATES}" ]] && { echo "${PROXMOX_STORAGE_TEMPLATES}"; return; }

  storage_exists "local" && { echo "local"; return; }

  pvesm status | awk 'NR>1 {print $1; exit}'
}

discover_template() {
  [[ -n "${PROXMOX_TEMPLATE}" ]] && { echo "${PROXMOX_TEMPLATE}"; return; }

  local t
  t="$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-12-standard_.*_amd64\.tar\.zst$' | sort -V | tail -n1)"
  [[ -n "${t}" ]] || die "Nao encontrei template Debian 12."
  echo "${t}"
}

ensure_template_downloaded() {
  local storage="$1"
  local template="$2"

  if pveam list "${storage}" 2>/dev/null | awk '{print $1}' | grep -qx "${template}"; then
    log_info "Template ja existe: ${template}"
    return
  fi

  log_info "A transferir template: ${template}"
  pveam download "${storage}" "${template}"
}

next_vmid() {
  [[ -n "${TERRAFORM_VMID}" ]] && { echo "${TERRAFORM_VMID}"; return; }
  pvesh get /cluster/nextid
}

gen_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true
}

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
  GIT_REPO="$(trim_value "${GIT_REPO}")"
  GIT_BRANCH="$(trim_value "${GIT_BRANCH}")"

  HOSTNAME_CT="$(trim_value "${HOSTNAME_CT}")"

  TERRAFORM_IP="$(trim_value "${TERRAFORM_IP}")"
  TERRAFORM_GATEWAY="$(trim_value "${TERRAFORM_GATEWAY}")"
  TERRAFORM_NAMESERVER="$(trim_value "${TERRAFORM_NAMESERVER}")"
  TERRAFORM_VMID="$(trim_value "${TERRAFORM_VMID}")"
  TERRAFORM_VLAN="$(trim_value "${TERRAFORM_VLAN}")"

  TERRAFORM_CORES="$(normalize_optional_numeric "${TERRAFORM_CORES}" "1")"
  TERRAFORM_RAM="$(normalize_optional_numeric "${TERRAFORM_RAM}" "1024")"
  TERRAFORM_SWAP="$(normalize_optional_numeric "${TERRAFORM_SWAP}" "1024")"
  TERRAFORM_DISK_GB="$(normalize_optional_numeric "${TERRAFORM_DISK_GB}" "5")"

  [[ -n "${HOSTNAME_CT}" ]] || die "HOSTNAME_CT vazio."

  if [[ -n "${TERRAFORM_VLAN}" ]] && ! [[ "${TERRAFORM_VLAN}" =~ ^[0-9]+$ ]]; then
    log_warn "VLAN invalida ('${TERRAFORM_VLAN}'); a ignorar."
    TERRAFORM_VLAN=""
  fi

  if [[ -n "${TERRAFORM_IP}" ]] && [[ "${TERRAFORM_IP}" != */* ]]; then
    log_warn "IP sem CIDR; a usar DHCP."
    TERRAFORM_IP=""
  fi
}

discover_gateway() {
  ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

discover_nameserver() {
  awk '/^nameserver / {print $2; exit}' /etc/resolv.conf 2>/dev/null
}

build_net0() {
  local bridge="$1"
  local vlan="${2:-}"
  local ipconf=""

  if [[ -z "${TERRAFORM_IP}" ]]; then
    ipconf="ip=dhcp"
  else
    local gw="${TERRAFORM_GATEWAY:-$(discover_gateway)}"
    local ns="${TERRAFORM_NAMESERVER:-$(discover_nameserver)}"

    ipconf="ip=${TERRAFORM_IP},gw=${gw}"
    TERRAFORM_NAMESERVER="${ns}"
  fi

  local base="name=eth0,bridge=${bridge},${ipconf}"

  if [[ -n "${vlan}" ]]; then
    base="${base},tag=${vlan}"
  fi

  echo "${base}"
}

get_ct_ip() {
  local vmid="$1"
  pct exec "$vmid" -- hostname -I 2>/dev/null | awk '{print $1}' || true
}

ensure_install_defaults

main() {
  local node bridge storage_root storage_tpl template vmid net0 ct_root_pw ct_ip compose_url

  node="$(discover_node)"
  bridge="$(discover_bridge)"
  storage_root="$(discover_storage_rootfs)"
  storage_tpl="$(discover_storage_templates)"
  template="$(discover_template)"
  ensure_template_downloaded "${storage_tpl}" "${template}"

  ip link show "${bridge}" >/dev/null 2>&1 || die "Bridge ${bridge} nao existe."

  vmid="$(next_vmid)"
  net0="$(build_net0 "${bridge}" "${TERRAFORM_VLAN}")"
  ct_root_pw="$(gen_password)"

  compose_url="${GIT_URL}/${GIT_USER}/${GIT_REPO}/raw/branch/${GIT_BRANCH}/terraform/docker-compose.yml"

  log_info "Criar CT ${vmid}"
  pct create "${vmid}" "${storage_tpl}:vztmpl/${template}" \
    --hostname "${HOSTNAME_CT}" \
    --cores "${TERRAFORM_CORES}" \
    --memory "${TERRAFORM_RAM}" \
    --swap "${TERRAFORM_SWAP}" \
    --rootfs "${storage_root}:${TERRAFORM_DISK_GB}" \
    --net0 "${net0}" \
    --unprivileged 1 \
    --features nesting=1 \
    --password "${ct_root_pw}"

  pct start "${vmid}"
  sleep 5

  pct exec "${vmid}" -- bash -lc "
    apt-get update
    apt-get install -y curl docker.io docker-compose
    mkdir -p /opt/terraform
    curl -fL ${compose_url} -o /opt/terraform/docker-compose.yml
  "

  ct_ip="$(get_ct_ip "${vmid}")"

  echo "=========================================="
  echo "CT_VMID=${vmid}"
  echo "CT_IP=${ct_ip}"
  echo "ROOT_PASS=${ct_root_pw}"
  echo "=========================================="
}

main "$@"