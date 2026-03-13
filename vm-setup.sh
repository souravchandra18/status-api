#!/bin/bash
# =============================================================================
# vm-setup.sh — Run this on a FRESH GCP VM to install all required tools.
# The bootstrap.sh will call this automatically, but you can also run it
# manually if you SSH into the VM directly.
#
# Tools installed:
#   - Docker
#   - Terraform 1.8.5
#   - Python 3 + pip packages (pytest, bandit, semgrep)
#   - Trivy (container scanner)
#   - TruffleHog (secrets scanner)
#   - git, curl, unzip, jq
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "╔══════════════════════════════════════════════╗"
echo "║   VM Tool Setup — Status API DevSecOps      ║"
echo "╚══════════════════════════════════════════════╝"

# ── System packages ───────────────────────────────────────────────────────────
echo ""
echo " Installing system packages..."
apt-get update -y -qq
apt-get install -y -qq \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  git \
  unzip \
  jq \
  python3 \
  python3-pip \
  python3-venv \
  nano \
  htop \
  wget

# ── Docker ────────────────────────────────────────────────────────────────────
echo ""
echo " Installing Docker..."
if command -v docker &>/dev/null; then
  echo "  Docker already installed: $(docker --version)"
else
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /usr/share/keyrings/docker.gpg

  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io

  # Allow current user to run docker without sudo
  CURRENT_USER=$(logname 2>/dev/null || whoami)
  usermod -aG docker "$CURRENT_USER" 2>/dev/null || true
  chmod 666 /var/run/docker.sock

  echo "  ✅ Docker installed: $(docker --version)"
fi

# ── Terraform ─────────────────────────────────────────────────────────────────
echo ""
echo " Installing Terraform..."
if command -v terraform &>/dev/null; then
  echo "  Terraform already installed: $(terraform --version | head -1)"
else
  TERRAFORM_VERSION="1.8.5"
  curl -sLo /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
  unzip -o /tmp/terraform.zip -d /usr/local/bin/ terraform
  chmod +x /usr/local/bin/terraform
  rm /tmp/terraform.zip
  echo "  ✅ Terraform installed: $(terraform --version | head -1)"
fi

# ── Python packages ───────────────────────────────────────────────────────────
echo ""
echo " Installing Python packages..."
pip install fastapi==0.111.0 \
  uvicorn[standard]==0.30.1 \
  structlog==24.2.0 \
  google-cloud-secret-manager==2.20.0 \
  google-cloud-monitoring==2.22.0 \
  protobuf==4.25.3 \
  httpx==0.27.0 \
  pytest==8.2.2 \
  pytest-asyncio==0.23.7 \
  pytest-cov==5.0.0 \
  bandit==1.7.9 \
  semgrep

echo "  ✅ Python packages installed"

# ── Trivy ─────────────────────────────────────────────────────────────────────
echo ""
echo " Installing Trivy..."
if command -v trivy &>/dev/null; then
  echo "  Trivy already installed: $(trivy --version | head -1)"
else
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
    | sh -s -- -b /usr/local/bin
  echo "  ✅ Trivy installed: $(trivy --version | head -1)"
fi

# ── TruffleHog ────────────────────────────────────────────────────────────────
echo ""
echo " Installing TruffleHog..."
if command -v trufflehog &>/dev/null; then
  echo "  TruffleHog already installed"
else
  curl -sSfL \
    https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
    | sh -s -- -b /usr/local/bin
  echo "  ✅ TruffleHog installed"
fi

# ── gcloud (if not already present) ──────────────────────────────────────────
echo ""
echo " Checking gcloud..."
if command -v gcloud &>/dev/null; then
  echo "  gcloud already installed: $(gcloud --version | head -1)"
else
  echo "  Installing gcloud SDK..."
  curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts
  source /root/google-cloud-sdk/path.bash.inc 2>/dev/null || \
    echo "  Add gcloud to PATH: source ~/google-cloud-sdk/path.bash.inc"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   ✅  All tools installed successfully!      ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  docker      : $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
echo "║  terraform   : $(terraform --version 2>/dev/null | head -1 | awk '{print $2}')"
echo "║  python3     : $(python3 --version 2>/dev/null)"
echo "║  bandit      : $(bandit --version 2>/dev/null | head -1)"
echo "║  trivy       : $(trivy --version 2>/dev/null | head -1)"
echo "║  git         : $(git --version 2>/dev/null)"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Next: run ./bootstrap.sh to set up GCP infrastructure"
