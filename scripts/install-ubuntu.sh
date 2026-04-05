#!/usr/bin/env bash
# scripts/install-ubuntu.sh
# ─────────────────────────────────────────────────────────────────────────────
# Installs all prerequisites for nginx-sec-lab on Ubuntu 22.04 / 24.04 LTS.
# Run once on a fresh host before 'task check'.
#
# Usage:
#   chmod +x scripts/install-ubuntu.sh
#   sudo bash scripts/install-ubuntu.sh
#
# What it installs:
#   - Docker Engine (official Docker repo, not snap)
#   - kubectl
#   - kind
#   - helm
#   - helmfile
#   - task (Taskfile runner)
#   - step-cli (local CA)
#   - cilium CLI  (optional — only needed for CNI=cilium)
#   - jq, curl, git, python3  (utilities)
#
# All tools installed to /usr/local/bin unless noted.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
info() { echo -e "  ${CYAN}→${NC}  $*"; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; exit 1; }

header() {
  echo ""
  echo -e "${CYAN}${BOLD}── $* ${NC}"
}

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  fail "Run with sudo: sudo bash scripts/install-ubuntu.sh"
fi

# ── OS check ──────────────────────────────────────────────────────────────────
if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu. Detected: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2)"
  warn "Continuing anyway — some steps may fail on non-Ubuntu systems."
fi

UBUNTU_VERSION=$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"')
ARCH=$(dpkg --print-architecture)
info "Ubuntu $UBUNTU_VERSION  |  arch: $ARCH"

# ── System update & base packages ─────────────────────────────────────────────
header "System packages"
apt-get update -qq
apt-get install -y -qq \
  curl wget git jq python3 python3-pip \
  apt-transport-https ca-certificates gnupg \
  lsb-release software-properties-common \
  iproute2 net-tools
ok "Base packages installed"

# ── Docker Engine ─────────────────────────────────────────────────────────────
header "Docker Engine"
if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
  ok "Docker already installed (v${DOCKER_VER}) — skipping"
else
  info "Adding Docker apt repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
  ok "Docker Engine installed"
fi

# Add current user to docker group (avoids sudo for docker commands)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [[ -n "$REAL_USER" ]] && ! groups "$REAL_USER" | grep -q docker; then
  usermod -aG docker "$REAL_USER"
  warn "Added $REAL_USER to docker group — log out and back in for this to take effect"
  warn "Or run: newgrp docker"
fi

# ── kubectl ───────────────────────────────────────────────────────────────────
header "kubectl"
if command -v kubectl &>/dev/null; then
  ok "kubectl already installed — skipping"
else
  info "Installing kubectl..."
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  apt-get update -qq
  apt-get install -y -qq kubectl
  ok "kubectl installed ($(kubectl version --client --short 2>/dev/null || kubectl version --client -o json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["clientVersion"]["gitVersion"])'))"
fi

# ── kind ──────────────────────────────────────────────────────────────────────
header "kind"
KIND_VERSION="v0.22.0"
if command -v kind &>/dev/null; then
  ok "kind already installed — skipping"
else
  info "Installing kind ${KIND_VERSION}..."
  curl -fsSLo /usr/local/bin/kind \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  chmod +x /usr/local/bin/kind
  ok "kind installed ($(kind version))"
fi

# ── Helm ──────────────────────────────────────────────────────────────────────
header "Helm"
if command -v helm &>/dev/null; then
  ok "Helm already installed — skipping"
else
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "Helm installed ($(helm version --short))"
fi

# ── Helmfile ──────────────────────────────────────────────────────────────────
header "Helmfile"
HELMFILE_VERSION="0.162.0"
if command -v helmfile &>/dev/null; then
  ok "Helmfile already installed — skipping"
else
  info "Installing Helmfile ${HELMFILE_VERSION}..."
  curl -fsSLo /tmp/helmfile.tar.gz \
    "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${ARCH}.tar.gz"
  tar -xzf /tmp/helmfile.tar.gz -C /usr/local/bin helmfile
  chmod +x /usr/local/bin/helmfile
  rm /tmp/helmfile.tar.gz
  ok "Helmfile installed ($(helmfile version))"
fi

# Helm diff plugin — required by helmfile
if ! helm plugin list | grep -q diff; then
  info "Installing helm-diff plugin..."
  helm plugin install https://github.com/databus23/helm-diff
  ok "helm-diff installed"
else
  ok "helm-diff already installed"
fi

# ── Task (Taskfile runner) ─────────────────────────────────────────────────────
header "Task"
TASK_VERSION="v3.35.1"
if command -v task &>/dev/null; then
  ok "Task already installed — skipping"
else
  info "Installing Task ${TASK_VERSION}..."
  curl -fsSLo /tmp/task.tar.gz \
    "https://github.com/go-task/task/releases/download/${TASK_VERSION}/task_linux_${ARCH}.tar.gz"
  tar -xzf /tmp/task.tar.gz -C /usr/local/bin task
  chmod +x /usr/local/bin/task
  rm /tmp/task.tar.gz
  ok "Task installed ($(task --version))"
fi

# ── step-cli ──────────────────────────────────────────────────────────────────
header "step-cli (local CA)"
STEP_VERSION="0.25.2"
if command -v step &>/dev/null; then
  ok "step already installed — skipping"
else
  info "Installing step-cli ${STEP_VERSION}..."
  # Determine deb package arch name
  STEP_ARCH="amd64"
  [[ "$ARCH" == "arm64" ]] && STEP_ARCH="arm64"

  curl -fsSLo /tmp/step.deb \
    "https://dl.smallstep.com/gh-release/cli/gh-release-header/v${STEP_VERSION}/step-cli_${STEP_VERSION}_${STEP_ARCH}.deb"
  dpkg -i /tmp/step.deb
  rm /tmp/step.deb
  ok "step installed ($(step version))"
fi

# ── Cilium CLI (optional) ────────────────────────────────────────────────────
header "Cilium CLI (optional — needed for CNI=cilium)"
CILIUM_VERSION="v0.16.4"
if command -v cilium &>/dev/null; then
  ok "cilium CLI already installed — skipping"
else
  info "Installing Cilium CLI ${CILIUM_VERSION}..."
  curl -fsSLo /tmp/cilium-linux-${ARCH}.tar.gz \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_VERSION}/cilium-linux-${ARCH}.tar.gz"
  tar -xzf /tmp/cilium-linux-${ARCH}.tar.gz -C /usr/local/bin
  chmod +x /usr/local/bin/cilium
  rm /tmp/cilium-linux-${ARCH}.tar.gz
  ok "Cilium CLI installed ($(cilium version --client))"
fi

# ── IP forwarding ─────────────────────────────────────────────────────────────
header "Kernel / network settings"

# Enable IP forwarding — required for kind node-to-node routing
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p /etc/sysctl.conf >/dev/null
  ok "IP forwarding enabled (net.ipv4.ip_forward=1)"
else
  ok "IP forwarding already enabled"
fi

# Increase inotify limits — kind clusters with many pods can hit defaults
if ! grep -q "fs.inotify.max_user_watches" /etc/sysctl.conf 2>/dev/null; then
  cat >> /etc/sysctl.conf << 'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF
  sysctl -p /etc/sysctl.conf >/dev/null
  ok "inotify limits increased"
else
  ok "inotify limits already configured"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}Installation complete${NC}"
echo ""
echo "  Tool versions:"
for tool in docker kubectl kind helm helmfile task step; do
  if command -v "$tool" &>/dev/null; then
    printf "    %-12s %s\n" "$tool" "$(command -v $tool)"
  fi
done
echo ""

if [[ -n "${REAL_USER:-}" ]] && ! groups "$REAL_USER" 2>/dev/null | grep -q docker; then
  echo -e "${YELLOW}  ACTION REQUIRED: Log out and back in (or run 'newgrp docker')${NC}"
  echo -e "${YELLOW}  to use Docker without sudo.${NC}"
  echo ""
fi

echo -e "  Next steps:"
echo -e "    ${CYAN}task check${NC}    — verify all tools"
echo -e "    ${CYAN}task ca:init${NC}  — create local CA (one-time)"
echo -e "    ${CYAN}task up${NC}       — spin up the full lab"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
