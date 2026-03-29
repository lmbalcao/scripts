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

GIT_URL="${GIT_URL:-https://github.com}"
GIT_USER="${GIT_USER:-lmbalcao}"
GIT_REPO="${GIT_REPO:-docker}"
GIT_BRANCH="${GIT_BRANCH:-master}"

HOSTNAME_CT="${HOSTNAME_CT:-dev-terraform}"

TERRAFORM_VLAN="${VLAN:-${TERRAFORM_VLAN:-35}}"

TERRAFORM_IP="${TERRAFORM_IP:-192.168.35.100/24}"
TERRAFORM_GATEWAY="${TERRAFORM_GATEWAY:-192.168.35.1}"
TERRAFORM_NAMESERVER="${DNS_SERVER:-${TERRAFORM_NAMESERVER:-192.168.35.1}}"
TERRAFORM_SEARCHDOMAIN="${DNS_DOMAIN:-${TERRAFORM_SEARCHDOMAIN:-}}"
TERRAFORM_VMID="${TERRAFORM_VMID:-}"

TERRAFORM_CORES="${STACK_CORES:-${TERRAFORM_CORES:-4}}"
TERRAFORM_RAM="${STACK_RAM:-${TERRAFORM_RAM:-4096}}"
TERRAFORM_SWAP="${STACK_SWAP:-${TERRAFORM_SWAP:-1024}}"
TERRAFORM_DISK_GB="${STACK_DISK_GB:-${TERRAFORM_DISK_GB:-5}}"

PROXMOX_NODE="${PROXMOX_NODE:-}"
PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-}"
PROXMOX_STORAGE_TEMPLATES="${PROXMOX_STORAGE_TEMPLATES:-}"
PROXMOX_TEMPLATE="${PROXMOX_TEMPLATE:-}"

[[ "${EUID}" -eq 0 || "${DEV_INSTALL_SKIP_ROOT_CHECK:-0}" == "1" ]] || die "Executa como root."

for cmd in pct pvesh pvesm pveam awk sed grep ip head tr qm hostname; do
  need_cmd "$cmd"
done

discover_node() {
  [[ -n "${PROXMOX_NODE}" ]] && { echo "${PROXMOX_NODE}"; return; }
  hostname -s
}

discover_bridge() {
  [[ -n "${PROXMOX_BRIDGE}" ]] && { echo "${PROXMOX_BRIDGE}"; return; }
  echo "vmbr0"
}

storage_exists() {
  pvesm status --storage "$1" >/dev/null 2>&1
}

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
  local storage="$1"
  local template="$2"

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

build_raw_url() {
  local path="$1"
  local base="${GIT_URL%/}"

  case "$base" in
    https://github.com|http://github.com|https://www.github.com|http://www.github.com)
      echo "https://raw.githubusercontent.com/${GIT_USER}/${GIT_REPO}/${GIT_BRANCH}/${path}"
      ;;
    *)
      echo "${base}/${GIT_USER}/${GIT_REPO}/raw/branch/${GIT_BRANCH}/${path}"
      ;;
  esac
}

main() {
  local node bridge storage_root storage_tpl template vmid net0 pass ip compose

  node="$(discover_node)"
  bridge="$(discover_bridge)"
  storage_root="$(discover_storage_rootfs)"
  storage_tpl="$(discover_storage_templates)"
  template="$(discover_template)"

  ensure_template_downloaded "$storage_tpl" "$template"

  # valida bridge
  ip link show "$bridge" >/dev/null 2>&1 || die "Bridge ${bridge} nao existe"

  vmid="$(next_vmid)"
  net0="$(build_net0 "$bridge")"
  pass="$(gen_password)"

  compose="$(build_raw_url "terraform/docker-compose.yml")"

  log_info "Criar CT ${vmid}"

  pct create "$vmid" "${storage_tpl}:vztmpl/${template}" \
    --hostname "$HOSTNAME_CT" \
    --cores "$TERRAFORM_CORES" \
    --memory "$TERRAFORM_RAM" \
    --swap "$TERRAFORM_SWAP" \
    --rootfs "${storage_root}:${TERRAFORM_DISK_GB}" \
    --net0 "$net0" \
    --nameserver "$TERRAFORM_NAMESERVER" \
    --unprivileged 1 \
    --features nesting=1 \
    --password "$pass"

  if [[ -n "${TERRAFORM_SEARCHDOMAIN}" ]]; then
    pct set "$vmid" --searchdomain "$TERRAFORM_SEARCHDOMAIN"
  fi

  pct start "$vmid"
  sleep 5

  pct exec "$vmid" -- bash -lc "
    apt-get update
    apt-get install -y curl docker.io docker-compose
    mkdir -p /opt/terraform
    curl -fL ${compose} -o /opt/terraform/docker-compose.yml
  "

  mkdir -p /opt
  git clone https://github.com/lmbalcao/terraform /opt/terraform




  ip="$(get_ct_ip "$vmid")"

  echo "======================================"
  echo "CT_VMID=$vmid"
  echo "CT_IP=$ip"
  echo "ROOT_PASS=$pass"
  echo "======================================"
}

main "$@"
