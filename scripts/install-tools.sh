#!/usr/bin/env bash
# Instala as ferramentas usadas pelo Claude Code neste ambiente.
# Corre como root ou com sudo: bash install-tools.sh
set -euo pipefail

apt-get update -qq

echo "=== Base tools ==="
apt-get install -y -qq \
  git \
  curl \
  wget \
  jq \
  unzip \
  gnupg \
  ca-certificates \
  lsb-release \
  openssh-client

echo "=== Python ==="
apt-get install -y -qq python3 python3-pip python3-venv

echo "=== Node.js (via NodeSource) ==="
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
else
  echo "  node $(node --version) já instalado"
fi

echo "=== Terraform ==="
if ! command -v terraform &>/dev/null; then
  wget -q -O /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/1.7.5/terraform_1.7.5_linux_amd64.zip"
  unzip -q /tmp/terraform.zip -d /usr/local/bin/
  rm /tmp/terraform.zip
  chmod +x /usr/local/bin/terraform
else
  echo "  terraform $(terraform version -json | jq -r '.terraform_version') já instalado"
fi

echo "=== Forgejo/Gitea CLI (tea) ==="
if ! command -v tea &>/dev/null; then
  TEA_VERSION="0.9.2"
  wget -q -O /usr/local/bin/tea \
    "https://dl.gitea.com/tea/${TEA_VERSION}/tea-${TEA_VERSION}-linux-amd64"
  chmod +x /usr/local/bin/tea
else
  echo "  tea já instalado"
fi

echo "=== Docker CLI ==="
if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce-cli
else
  echo "  docker $(docker --version) já instalado"
fi

echo ""
echo "=== Versões instaladas ==="
git --version
curl --version | head -1
jq --version
python3 --version
node --version
npm --version
terraform version 2>/dev/null || true
tea --version 2>/dev/null || true
docker --version 2>/dev/null || true

echo ""
echo "✅ Done!"
