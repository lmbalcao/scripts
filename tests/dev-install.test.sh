#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/dev-install.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

MOCKBIN="${TMP_DIR}/bin"
mkdir -p "${MOCKBIN}"

# ── pct ───────────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/pct" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "${TMP_DIR}/pct.log"
case "\$1" in
  create|set|start)
    exit 0
    ;;
  exec)
    # pct exec <vmid> -- hostname -I
    if [[ "\$4" == "hostname" && "\$5" == "-I" ]]; then
      echo "192.168.35.100"
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "${MOCKBIN}/pct"

# ── pvesh ─────────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/pvesh" <<'EOF'
#!/bin/bash
if [[ "$1" == "get" && "$2" == "/cluster/nextid" ]]; then
  echo "1234"
  exit 0
fi
# Storage list for any node — returns local-lvm (rootdir) and local (vztmpl+rootdir)
if [[ "$1" == "get" && "$2" =~ ^/nodes/.*/storage$ ]]; then
  echo '[{"storage":"local-lvm","content":"rootdir,images","active":1},{"storage":"local","content":"vztmpl,backup,iso,rootdir","active":1}]'
  exit 0
fi
exit 0
EOF
chmod +x "${MOCKBIN}/pvesh"

# ── pvesm ─────────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/pvesm" <<EOF
#!/bin/bash
if [[ "\$1" == "status" ]]; then
  exit 0
fi
EOF
chmod +x "${MOCKBIN}/pvesm"

# ── pveam ─────────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/pveam" <<EOF
#!/bin/bash
case "\$1" in
  available)
    printf 'system debian-12-standard_12.7-1_amd64.tar.zst\n'
    ;;
  list)
    exit 1
    ;;
  download)
    exit 0
    ;;
esac
EOF
chmod +x "${MOCKBIN}/pveam"

# ── pveum ─────────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/pveum" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "${TMP_DIR}/pveum.log"
case "\$1" in
  user)
    # pveum user token add terraform@pve terraform --expire 0 --privsep 0 --output-format json
    if [[ "\$2" == "token" && "\$3" == "add" ]]; then
      echo '{"value":"mock-token-uuid-abcd1234"}'
    fi
    exit 0
    ;;
  role)
    exit 0
    ;;
  aclmod)
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "${MOCKBIN}/pveum"

# ── ip ────────────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/ip" <<EOF
#!/bin/bash
if [[ "\$1" == "link" && "\$2" == "show" ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "${MOCKBIN}/ip"

# ── openssl ───────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/openssl" <<EOF
#!/bin/bash
echo 'MockPasswordBase64Value1234567890'
EOF
chmod +x "${MOCKBIN}/openssl"

# ── curl ──────────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/curl" <<'EOF'
#!/bin/bash
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    out="$2"
    shift 2
    continue
  fi
  shift
done
[[ -n "${out}" ]] && : > "${out}"
exit 0
EOF
chmod +x "${MOCKBIN}/curl"

# ── qm ────────────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/qm" <<EOF
#!/bin/bash
exit 0
EOF
chmod +x "${MOCKBIN}/qm"

# ── python3 ───────────────────────────────────────────────────────────────────
# Minimal python3 mock that handles the two patterns used by dev-install.sh:
#   1. node_storages_with_content  — reads JSON array, prints storage names by content type
#   2. ensure_proxmox_terraform_token — reads JSON object, prints .value
cat > "${MOCKBIN}/python3" <<'PYEOF'
#!/usr/bin/env python3
import json, sys

# Inline script passed as -c
if len(sys.argv) >= 2 and sys.argv[1] == '-c':
    exec(sys.argv[2], {'__name__': '__main__'})
    sys.exit(0)

# Script read from stdin (python3 - arg1 arg2 ...)
src = sys.stdin.read()
# Inject argv so the script can use sys.argv
sys.argv = sys.argv[1:]  # drop 'python3', keep remaining args
exec(src, {'__name__': '__main__'})
PYEOF
chmod +x "${MOCKBIN}/python3"

# ── hostname ──────────────────────────────────────────────────────────────────
cat > "${MOCKBIN}/hostname" <<'EOF'
#!/bin/bash
case "$1" in
  -s) echo "pve-node" ;;
  -I) echo "192.168.1.1" ;;
  *)  echo "pve-node" ;;
esac
EOF
chmod +x "${MOCKBIN}/hostname"

# ── system tools ──────────────────────────────────────────────────────────────
for cmd in awk sed grep head tr apt-get sleep; do
  ln -s "$(command -v "${cmd}")" "${MOCKBIN}/${cmd}" 2>/dev/null || true
done

# ── Run script ────────────────────────────────────────────────────────────────
OUTPUT="$(env \
  PATH="${MOCKBIN}:/usr/bin:/bin" \
  DEV_INSTALL_SKIP_ROOT_CHECK="1" \
  DNS_DOMAIN="lab.internal" \
  DNS_SERVER="192.168.35.53" \
  VLAN="77" \
  bash "${SCRIPT_PATH}" 2>&1
)"

# ── Assertions ────────────────────────────────────────────────────────────────

# CT created with correct VMID, storage, network, and VLAN
grep -q 'create 1234 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst' "${TMP_DIR}/pct.log"
grep -q '1234.*--rootfs local-lvm:10' "${TMP_DIR}/pct.log"
grep -q '1234.*--net0 name=eth0,bridge=vmbr0,ip=dhcp,tag=77' "${TMP_DIR}/pct.log"

# Nameserver and searchdomain applied
grep -q 'set 1234 --nameserver 192.168.35.53' "${TMP_DIR}/pct.log"
grep -q 'set 1234 --searchdomain lab.internal' "${TMP_DIR}/pct.log"

# Proxmox terraform user and token were created
grep -q 'user add terraform@pve' "${TMP_DIR}/pveum.log"
grep -q 'user token add terraform@pve terraform' "${TMP_DIR}/pveum.log"

# Success box printed with VMID
grep -q 'CT VMID:.*1234' <<< "${OUTPUT}"

echo "dev-install test passed"
