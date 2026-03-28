#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/dev-install.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

MOCKBIN="${TMP_DIR}/bin"
mkdir -p "${MOCKBIN}"

cat > "${MOCKBIN}/pct" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "${TMP_DIR}/pct.log"
case "\$1" in
  create|set|start)
    exit 0
    ;;
  exec)
    if [[ "\$3" == "hostname" && "\$4" == "-I" ]]; then
      echo "192.168.35.100"
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "${MOCKBIN}/pct"

cat > "${MOCKBIN}/pvesh" <<EOF
#!/bin/bash
if [[ "\$1" == "get" && "\$2" == "/cluster/nextid" ]]; then
  echo "1234"
fi
EOF
chmod +x "${MOCKBIN}/pvesh"

cat > "${MOCKBIN}/pvesm" <<EOF
#!/bin/bash
if [[ "\$1" == "status" ]]; then
  exit 0
fi
EOF
chmod +x "${MOCKBIN}/pvesm"

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

cat > "${MOCKBIN}/ip" <<EOF
#!/bin/bash
if [[ "\$1" == "link" && "\$2" == "show" ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "${MOCKBIN}/ip"

cat > "${MOCKBIN}/openssl" <<EOF
#!/bin/bash
echo 'MockPasswordBase64Value1234567890'
EOF
chmod +x "${MOCKBIN}/openssl"

cat > "${MOCKBIN}/curl" <<EOF
#!/bin/bash
out=""
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-o" ]]; then
    out="\$2"
    shift 2
    continue
  fi
  shift
done
[[ -n "\${out}" ]] && : > "\${out}"
exit 0
EOF
chmod +x "${MOCKBIN}/curl"

cat > "${MOCKBIN}/qm" <<EOF
#!/bin/bash
exit 0
EOF
chmod +x "${MOCKBIN}/qm"

for cmd in awk sed grep head tr hostname apt-get sleep; do
  ln -s "/usr/bin/${cmd}" "${MOCKBIN}/${cmd}" 2>/dev/null || ln -s "/bin/${cmd}" "${MOCKBIN}/${cmd}"
done

OUTPUT="$(env \
  PATH="${MOCKBIN}:/usr/bin:/bin" \
  DEV_INSTALL_SKIP_ROOT_CHECK="1" \
  DNS_DOMAIN="lab.internal" \
  DNS_SERVER="192.168.35.53" \
  VLAN="77" \
  bash "${SCRIPT_PATH}" 2>&1
)"

grep -q 'CT_VMID=1234' <<< "${OUTPUT}"
grep -q 'create 1234 .*--net0 name=eth0,bridge=vmbr0,ip=192.168.35.100/24,gw=192.168.35.1,tag=77 .*--nameserver 192.168.35.53' "${TMP_DIR}/pct.log"
grep -q 'set 1234 --searchdomain lab.internal' "${TMP_DIR}/pct.log"

echo "dev-install test passed"
