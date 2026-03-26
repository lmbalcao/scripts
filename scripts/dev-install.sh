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

# ============================================================
# VARS
# ============================================================

GIT_URL="${GIT_URL:-https://forgejo.lbtec.org}"
GIT_USER="${GIT_USER:-lmbalcao}"
GIT_REPO="${GIT_REPO:-docker}"
GIT_BRANCH="${GIT_BRANCH:-master}"

HOSTNAME_CT="${HOSTNAME_CT:-dev-terraform}"

TERRAFORM_VLAN="${VLAN:-${TERRAFORM_VLAN:-99}}"
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

  grep -qE '^\s*auto\s+vmbr0\b|^\s*iface\s+vmbr0\b' /etc/network/interfaces 2>/dev/null && {
    echo "vmbr0"
    return
  }

  local b
  b="$(awk '/^\s*iface\s+vmbr[0-9]+/ {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)"
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
  t="$(
    pveam available --section system 2>/dev/null \
      | awk '{print $2}' \
      | grep -E '^debian-12-standard_.*_amd64\.tar\.zst$' \
      | sort -V \
      | tail -n1
  )"

  [[ -n "${t}" ]] || die "N�o encontrei template Debian 12."
  echo "${t}"
}

ensure_template_downloaded() {
  local storage="$1"
  local template="$2"

  if pveam list "${storage}" 2>/dev/null | awk '{print $1}' | grep -qx "${template}"; then
    log_info "Template j� existe: ${template}"
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
    log_warn "VLAN inv�lida ('${TERRAFORM_VLAN}'); a ignorar tag VLAN."
    TERRAFORM_VLAN=""
  fi

  if [[ -n "${TERRAFORM_VMID}" ]] && ! [[ "${TERRAFORM_VMID}" =~ ^[0-9]+$ ]]; then
    log_warn "VMID inv�lido ('${TERRAFORM_VMID}'); a usar pr�ximo VMID autom�tico."
    TERRAFORM_VMID=""
  fi

  if [[ -n "${TERRAFORM_IP}" ]] && [[ "${TERRAFORM_IP}" != */* ]]; then
    log_warn "IP est�tico sem CIDR ('${TERRAFORM_IP}'); a usar DHCP."
    TERRAFORM_IP=""
    TERRAFORM_GATEWAY=""
    TERRAFORM_NAMESERVER=""
  fi

  if [[ -n "${SSH_PUBKEY_PATH}" ]] && [[ ! -f "${SSH_PUBKEY_PATH}" ]]; then
    die "SSH_PUBKEY_PATH n�o existe: ${SSH_PUBKEY_PATH}"
  fi
}

validate_static_network_config() {
  local ip_cidr="$1"
  local gateway="$2"
  local nameserver="$3"

  if ! command -v python3 >/dev/null 2>&1; then
    log_warn "python3 n�o encontrado; valida��o avan�ada de rede est�tica foi ignorada."
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
    print(f"IP est�tico inv�lido: {ip_cidr}", file=sys.stderr)
    raise SystemExit(1)

try:
    gw = ipaddress.ip_address(gateway)
except Exception:
    print(f"Gateway inv�lido: {gateway}", file=sys.stderr)
    raise SystemExit(1)

if gw.version != iface.ip.version:
    print("Gateway e IP t�m vers�es diferentes (IPv4/IPv6).", file=sys.stderr)
    raise SystemExit(1)

if gw not in iface.network:
    print(f"Gateway {gateway} fora da subnet {iface.network} do IP {ip_cidr}.", file=sys.stderr)
    raise SystemExit(1)

if gw == iface.ip:
    print("IP est�tico n�o pode ser igual ao gateway.", file=sys.stderr)
    raise SystemExit(1)

if nameserver:
    try:
        ns = ipaddress.ip_address(nameserver)
    except Exception:
        print(f"Nameserver inv�lido: {nameserver}", file=sys.stderr)
        raise SystemExit(1)

    if ns.version != iface.ip.version:
        print("Nameserver e IP t�m vers�es diferentes (IPv4/IPv6).", file=sys.stderr)
        raise SystemExit(1)

if not iface.ip.is_private:
    print(f"AVISO: IP {iface.ip} n�o est� em faixa privada (confirma se � intencional).", file=sys.stderr)
PY
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
    [[ "${TERRAFORM_IP}" == */* ]] || die "TERRAFORM_IP tem de incluir CIDR."

    local gw="${TERRAFORM_GATEWAY:-}"
    local ns="${TERRAFORM_NAMESERVER:-}"

    [[ -n "${gw}" ]] || gw="$(discover_gateway)"
    [[ -n "${gw}" ]] || die "Gateway n�o encontrado."

    [[ -n "${ns}" ]] || ns="$(discover_nameserver)"
    [[ -n "${ns}" ]] || die "Nameserver n�o encontrado."

    validate_static_network_config "${TERRAFORM_IP}" "${gw}" "${ns}" || die "Configura��o de rede est�tica inv�lida."

    TERRAFORM_GATEWAY="${gw}"
    TERRAFORM_NAMESERVER="${ns}"
    ipconf="ip=${TERRAFORM_IP},gw=${gw}"
  fi

  local base="name=eth0,bridge=${bridge},${ipconf}"

  if [[ -n "${vlan}" ]]; then
    [[ "${vlan}" =~ ^[0-9]+$ ]] || die "VLAN inv�lida"
    base="${base},tag=${vlan}"
  fi

  echo "${base}"
}

setup_ct_ssh_key_and_authorize_on_host() {
  local vmid="$1"
  local ct_ssh_pubkey=""
  local local_node=""
  local cluster_nodes=""
  local n=""
  local node_ip=""

  log_info "A configurar chave SSH do CT e autorizar no host Proxmox..."

  pct exec "${vmid}" -- bash -lc '
    set -euo pipefail
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if [ ! -f /root/.ssh/id_ed25519 ]; then
      ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -C "stackctl-ct" >/dev/null
    fi
    chmod 600 /root/.ssh/id_ed25519
    chmod 644 /root/.ssh/id_ed25519.pub
  '

  ct_ssh_pubkey="$(pct exec "${vmid}" -- bash -lc 'cat /root/.ssh/id_ed25519.pub' | tr -d '\r')"
  [[ -n "${ct_ssh_pubkey}" ]] || die "Falha ao obter chave p�blica SSH do CT."

  install -d -m 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  if ! grep -qxF "${ct_ssh_pubkey}" /root/.ssh/authorized_keys; then
    echo "${ct_ssh_pubkey}" >> /root/.ssh/authorized_keys
    log_info "Chave p�blica do CT adicionada em /root/.ssh/authorized_keys do host."
  else
    log_info "Chave p�blica do CT j� autorizada no host."
  fi

  if [[ "${TERRAFORM_INJECT_SSH_KEY_ALL_NODES}" =~ ^(1|true|yes|on)$ ]]; then
    local_node="$(hostname -s 2>/dev/null || true)"

    cluster_nodes="$(
      pvesh get /nodes --output-format json 2>/dev/null \
        | tr -d '\n' \
        | grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)"$/\1/' \
        || true
    )"

    if [[ -z "${cluster_nodes}" ]]; then
      log_warn "N�o foi poss�vel listar nodes do cluster para propagar chave SSH."
      return 0
    fi

    for n in ${cluster_nodes}; do
      [[ -z "${n}" || "${n}" == "${local_node}" ]] && continue

      node_ip="$(getent ahostsv4 "${n}" 2>/dev/null | awk 'NR==1{print $1}' || true)"
      if [[ -z "${node_ip}" ]]; then
        log_warn "Node ${n} sem IP resolv�vel (ignorado)."
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
        "install -d -m 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && grep -qxF '${ct_ssh_pubkey}' /root/.ssh/authorized_keys || echo '${ct_ssh_pubkey}' >> /root/.ssh/authorized_keys" \
        >/dev/null 2>&1; then
        log_info "Chave p�blica propagada para node ${n} (${node_ip})."
      else
        log_warn "N�o foi poss�vel propagar chave para node ${n} (${node_ip}) (ignorado)."
      fi
    done
  fi
}

_PVE_TF_USER="terraform@pve"
_PVE_TF_ROLE="TerraformRole"
_PVE_TF_TOKEN_NAME="terraform-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8 || true)"
_PVE_TF_PRIVS="Datastore.AllocateSpace,Datastore.Audit,Pool.Allocate,Pool.Audit,SDN.Use,Sys.Audit,Sys.Console,Sys.Modify,VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Migrate,VM.PowerMgmt"

create_proxmox_terraform_user_token() {
  log_info "A criar utilizador Terraform no Proxmox (${_PVE_TF_USER})..."

  pveum user add "${_PVE_TF_USER}" --comment "Terraform automation user" 2>/dev/null \
    && log_info "Utilizador ${_PVE_TF_USER} criado." \
    || log_info "Utilizador ${_PVE_TF_USER} j� existe."

  if pveum role add "${_PVE_TF_ROLE}" --privs "${_PVE_TF_PRIVS}" 2>/dev/null; then
    log_info "Role ${_PVE_TF_ROLE} criada."
  else
    pveum role modify "${_PVE_TF_ROLE}" --privs "${_PVE_TF_PRIVS}" 2>/dev/null || true
    log_info "Role ${_PVE_TF_ROLE} j� existe (privil�gios actualizados)."
  fi

  pveum aclmod / --user "${_PVE_TF_USER}" --role "${_PVE_TF_ROLE}" 2>/dev/null || true
  log_info "ACL configurada: / -> ${_PVE_TF_USER}:${_PVE_TF_ROLE}"

  local token_json=""
  if token_json="$(pveum user token add "${_PVE_TF_USER}" "${_PVE_TF_TOKEN_NAME}" --expire 0 --privsep 0 --output-format json 2>/dev/null)"; then
    tf_token_value="$(printf '%s' "${token_json}" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')"
    log_info "Token API ${_PVE_TF_USER}!${_PVE_TF_TOKEN_NAME} criado."
  else
    tf_token_value=""
    log_warn "N�o foi poss�vel criar token '${_PVE_TF_TOKEN_NAME}'. Pode j� existir."
    log_warn "Se j� existir, o secret n�o � recuper�vel."
  fi
}

get_ct_ip() {
  local vmid="$1"
  local ip_addr=""

  if [[ -n "${TERRAFORM_IP}" ]]; then
    echo "${TERRAFORM_IP%%/*}"
    return 0
  fi

  ip_addr="$(
    pct exec "${vmid}" -- bash -lc \
      "ip -4 -o addr show dev eth0 scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1" \
      2>/dev/null || true
  )"

  echo "${ip_addr}"
}

prompt_settings() {
  local mode=""
  local input=""

  echo
  log_info "Terraform Installer - Configura��o"
  echo
  echo "Escolhe modo de instala��o:"
  echo "  1) Default (recomendado)"
  echo "  2) Custom"
  echo
  read -r -p "Op��o [1]: " mode < /dev/tty
  mode="$(trim_value "${mode:-1}")"
  [[ -n "${mode}" ]] || mode="1"

  if [[ "${mode}" != "2" ]]; then
    log_info "A usar configura��es default."
    return
  fi

  log_info "Modo custom - ENTER mant�m o valor actual"
  echo

  read -r -p "VLAN [${TERRAFORM_VLAN:-vazio}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_VLAN="${input}"

  read -r -p "IP est�tico com CIDR [${TERRAFORM_IP:-vazio=DHCP}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  if [[ -n "${input}" ]]; then
    TERRAFORM_IP="${input}"

    read -r -p "Gateway [${TERRAFORM_GATEWAY:-auto}]: " input < /dev/tty
    input="$(trim_value "${input}")"
    [[ -n "${input}" ]] && TERRAFORM_GATEWAY="${input}"

    read -r -p "Nameserver [${TERRAFORM_NAMESERVER:-auto}]: " input < /dev/tty
    input="$(trim_value "${input}")"
    [[ -n "${input}" ]] && TERRAFORM_NAMESERVER="${input}"
  fi

  read -r -p "VMID [${TERRAFORM_VMID:-auto}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_VMID="${input}"

  read -r -p "CPU cores [${TERRAFORM_CORES}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_CORES="${input}"

  read -r -p "RAM em MB [${TERRAFORM_RAM}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_RAM="${input}"

  read -r -p "SWAP em MB [${TERRAFORM_SWAP}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_SWAP="${input}"

  read -r -p "Disco em GB [${TERRAFORM_DISK_GB}]: " input < /dev/tty
  input="$(trim_value "${input}")"
  [[ -n "${input}" ]] && TERRAFORM_DISK_GB="${input}"

  echo
  log_info "Configura��o custom aplicada."
}

if [[ -c /dev/tty ]]; then
  prompt_settings < /dev/tty
else
  log_info "Modo n�o-interactivo detectado - a usar defaults."
fi

ensure_install_defaults

main() {
  local node=""
  local bridge=""
  local storage_root=""
  local storage_tpl=""
  local template=""
  local vmid=""
  local net0=""
  local ct_root_pw=""
  local tf_token_value=""
  local proxmox_api_url=""
  local ct_ip=""
  local compose_raw_url=""
  local ssh_key_opt=()

  node="$(discover_node)"
  [[ -n "${node}" ]] || die "PROXMOX_NODE n�o encontrado."

  bridge="$(discover_bridge)"
  [[ -n "${bridge}" ]] || die "PROXMOX_BRIDGE n�o encontrado."

  storage_root="$(discover_storage_rootfs)"
  [[ -n "${storage_root}" ]] || die "PROXMOX_STORAGE n�o encontrado."

  storage_tpl="$(discover_storage_templates)"
  [[ -n "${storage_tpl}" ]] || die "PROXMOX_STORAGE_TEMPLATES n�o encontrado."

  template="$(discover_template)"
  ensure_template_downloaded "${storage_tpl}" "${template}"

  vmid="$(next_vmid)"
  [[ -n "${vmid}" ]] || die "VMID falhou."

  if pct status "${vmid}" >/dev/null 2>&1; then
    die "J� existe um CT com VMID ${vmid}."
  fi
  if qm status "${vmid}" >/dev/null 2>&1; then
    die "J� existe uma VM com VMID ${vmid}."
  fi

  net0="$(build_net0 "${bridge}" "${TERRAFORM_VLAN}")"
  ct_root_pw="$(gen_password)"
  [[ -n "${ct_root_pw}" ]] || die "Falha a gerar password do root do CT."

  compose_raw_url="${GIT_URL}/${GIT_USER}/${GIT_REPO}/raw/branch/${GIT_BRANCH}/terraform/docker-compose.yml"
  proxmox_api_url="https://$(hostname -f 2>/dev/null || hostname -s):8006/api2/json"

  if [[ -n "${SSH_PUBKEY_PATH}" ]]; then
    ssh_key_opt=(--ssh-public-keys "${SSH_PUBKEY_PATH}")
  fi

  log_info "Configura��o:"
  echo "  NODE=${node}"
  echo "  BRIDGE=${bridge}"
  echo "  STORAGE_ROOT=${storage_root}"
  echo "  STORAGE_TEMPLATES=${storage_tpl}"
  echo "  TEMPLATE=${template}"
  echo "  VMID=${vmid}"
  echo "  HOSTNAME=${HOSTNAME_CT}"
  echo "  NET0=${net0}"
  echo "  CORES=${TERRAFORM_CORES}"
  echo "  RAM=${TERRAFORM_RAM}MB"
  echo "  SWAP=${TERRAFORM_SWAP}MB"
  echo "  DISK=${TERRAFORM_DISK_GB}GB"
  echo "  COMPOSE_URL=${compose_raw_url}"
  echo

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
    --password "${ct_root_pw}" \
    "${ssh_key_opt[@]}"

  if [[ -n "${TERRAFORM_IP}" && -n "${TERRAFORM_NAMESERVER}" ]]; then
    pct set "${vmid}" --nameserver "${TERRAFORM_NAMESERVER}"
  fi

  log_info "CT criado com sucesso."

  log_info "A iniciar setup do CT..."
  pct start "${vmid}"
  sleep 5

  log_info "A executar preflight, updates, Docker e preparar /opt/terraform..."
  pct exec "${vmid}" -- env \
    EXPECTED_GW="${TERRAFORM_GATEWAY}" \
    EXPECT_STATIC_IP="${TERRAFORM_IP}" \
    TERRAFORM_COMPOSE_RAW_URL="${compose_raw_url}" \
    bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive

      echo "[INFO] Preflight de rede no CT..."
      ip -4 addr show dev eth0 || true
      ip -4 route show || true

      if [ -n "${EXPECT_STATIC_IP:-}" ]; then
        if ! ip -4 route show default | grep -q "^default via "; then
          echo "[ERROR] Sem rota default no CT (modo IP est�tico)."
          exit 1
        fi

        if [ -n "${EXPECTED_GW:-}" ] && command -v ping >/dev/null 2>&1; then
          ping -c1 -W2 "${EXPECTED_GW}" >/dev/null 2>&1 || {
            echo "[ERROR] Gateway ${EXPECTED_GW} n�o responde a partir do CT."
            exit 1
          }
        fi
      fi

      if ! getent hosts deb.debian.org >/dev/null 2>&1; then
        echo "[ERROR] DNS falhou no CT (deb.debian.org n�o resolvido)."
        cat /etc/resolv.conf || true
        exit 1
      fi

      if ! timeout 6 bash -lc "cat </dev/null >/dev/tcp/deb.debian.org/80" >/dev/null 2>&1; then
        echo "[ERROR] Sem conectividade TCP para deb.debian.org:80."
        exit 1
      fi

      apt-get -o Acquire::Retries=3 update
      apt-get -o Acquire::Retries=3 upgrade -y

      apt-get install -y \
        curl \
        wget \
        git \
        ca-certificates \
        gnupg \
        lsb-release \
        openssh-client \
        rsync \
        util-linux

      apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

      install -m 0755 -d /etc/apt/keyrings
      rm -f /etc/apt/keyrings/docker.gpg
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg

      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

      mkdir -p /opt/terraform

      if [ -z "${TERRAFORM_COMPOSE_RAW_URL:-}" ]; then
        echo "[ERROR] Vari�vel TERRAFORM_COMPOSE_RAW_URL n�o definida."
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

  log_info "Setup do CT conclu�do."

  setup_ct_ssh_key_and_authorize_on_host "${vmid}"
  create_proxmox_terraform_user_token

  ct_ip="$(get_ct_ip "${vmid}")"

  echo
  echo "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"
  echo " Terraform  Instala��o conclu�da"
  echo "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"
  echo " CT_VMID                = ${vmid}"
  echo " CT_ROOT_PASSWORD       = ${ct_root_pw}"
  echo " CT_IP                  = ${ct_ip:-desconhecido}"
  echo " CT_HOSTNAME            = ${HOSTNAME_CT}"
  echo " CT_COMPOSE_FILE        = /opt/terraform/docker-compose.yml"
  echo "                                                "
  echo " PROXMOX_API_URL        = ${proxmox_api_url}"
  echo " PROXMOX_TF_USER        = ${_PVE_TF_USER}!${_PVE_TF_TOKEN_NAME}"
  echo " PROXMOX_TF_TOKEN       = ${tf_token_value:-'(n�o dispon�vel; token pode j� existir)'}"
  echo "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"

  log_warn "Guarda estas credenciais num gestor de passwords."
  log_info "Instala��o conclu�da com sucesso."
}

main "$@" 