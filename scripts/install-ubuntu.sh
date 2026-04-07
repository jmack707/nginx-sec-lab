#!/usr/bin/env bash
# scripts/install-ubuntu.sh
# Installs all prerequisites for nginx-sec-lab on Ubuntu 22.04 / 24.04 LTS.
# Usage: sudo bash scripts/install-ubuntu.sh
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()     { echo -e "  ${GREEN}✓${NC}  $*"; }
info()   { echo -e "  ${CYAN}→${NC}  $*"; }
warn()   { echo -e "  ${YELLOW}!${NC}  $*"; }
fail()   { echo -e "  ${RED}✗${NC}  $*"; exit 1; }
header() { echo ""; echo -e "${CYAN}${BOLD}── $* ${NC}"; }

[[ $EUID -ne 0 ]] && fail "Run with sudo: sudo bash scripts/install-ubuntu.sh"

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu. Continuing anyway..."
fi

UBUNTU_VERSION=$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"')
ARCH=$(dpkg --print-architecture)
info "Ubuntu $UBUNTU_VERSION | arch: $ARCH"

# ── Base packages ─────────────────────────────────────────────────────────────
header "System packages"
apt-get update -qq
apt-get install -y -qq \
  curl wget git jq python3 \
  apt-transport-https ca-certificates gnupg \
  lsb-release software-properties-common \
  iproute2 net-tools bash-completion
ok "Base packages installed"

# ── Docker ────────────────────────────────────────────────────────────────────
header "Docker Engine"
if command -v docker &>/dev/null; then
  ok "Docker already installed (v$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')) -- skipping"
else
  info "Adding Docker apt repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable docker && systemctl start docker
  ok "Docker Engine installed"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [[ -n "$REAL_USER" ]] && ! groups "$REAL_USER" | grep -q docker; then
  usermod -aG docker "$REAL_USER"
  warn "Added $REAL_USER to docker group -- log out and back in, or run: newgrp docker"
fi

# ── kubectl ───────────────────────────────────────────────────────────────────
header "kubectl"
if command -v kubectl &>/dev/null; then
  ok "kubectl already installed -- skipping"
else
  info "Installing kubectl..."
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq && apt-get install -y -qq kubectl
  ok "kubectl installed"
fi

# ── kubectl bash completion ──────────────────────────────────────────────────
header "kubectl bash completion"
if [[ -n "${REAL_USER:-}" ]]; then
  USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
  BASHRC="$USER_HOME/.bashrc"
  KCOMP_MARKER='# >>> nginx-sec-lab kubectl completion >>>'
  if [[ -f "$BASHRC" ]] && ! grep -qF "$KCOMP_MARKER" "$BASHRC"; then
    cat >> "$BASHRC" <<'EOF'

# >>> nginx-sec-lab kubectl completion >>>
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
# <<< nginx-sec-lab kubectl completion <<<
EOF
    chown "$REAL_USER:$REAL_USER" "$BASHRC"
    ok "kubectl completion + 'k' alias added to $BASHRC"
  else
    ok "kubectl completion already configured"
  fi
else
  warn "No REAL_USER detected -- skipping bashrc edit"
fi

# ── k3d ───────────────────────────────────────────────────────────────────────
header "k3d"
K3D_VERSION="v5.7.4"
if command -v k3d &>/dev/null; then
  ok "k3d already installed ($(k3d version | head -1)) -- skipping"
else
  info "Installing k3d ${K3D_VERSION}..."
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
    | TAG="${K3D_VERSION}" bash
  ok "k3d installed ($(k3d version | head -1))"
fi

# ── Helm ──────────────────────────────────────────────────────────────────────
header "Helm"
if command -v helm &>/dev/null; then
  ok "Helm already installed -- skipping"
else
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "Helm installed ($(helm version --short))"
fi

# ── Helmfile ──────────────────────────────────────────────────────────────────
header "Helmfile"
HELMFILE_VERSION="0.162.0"
if command -v helmfile &>/dev/null; then
  ok "Helmfile already installed -- skipping"
else
  info "Installing Helmfile ${HELMFILE_VERSION}..."
  curl -fsSLo /tmp/helmfile.tar.gz \
    "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${ARCH}.tar.gz"
  tar -xzf /tmp/helmfile.tar.gz -C /usr/local/bin helmfile
  chmod +x /usr/local/bin/helmfile && rm /tmp/helmfile.tar.gz
  ok "Helmfile installed ($(helmfile version))"
fi

# ── helm-diff plugin ─────────────────────────────────────────────────────────
header "helm-diff plugin"
if [[ -n "${REAL_USER:-}" ]]; then
  if ! sudo -u "$REAL_USER" helm plugin list 2>/dev/null | grep -q diff; then
    info "Installing helm-diff plugin for $REAL_USER..."
    sudo -u "$REAL_USER" helm plugin install https://github.com/databus23/helm-diff
    ok "helm-diff installed for $REAL_USER"
  else
    ok "helm-diff already installed for $REAL_USER"
  fi
else
  if ! helm plugin list 2>/dev/null | grep -q diff; then
    info "Installing helm-diff plugin..."
    helm plugin install https://github.com/databus23/helm-diff
    ok "helm-diff installed"
  else
    ok "helm-diff already installed"
  fi
fi

# ── Task ──────────────────────────────────────────────────────────────────────
header "Task (Taskfile runner)"
TASK_VERSION="v3.35.1"
if command -v task &>/dev/null; then
  ok "Task already installed -- skipping"
else
  info "Installing Task ${TASK_VERSION}..."
  curl -fsSLo /tmp/task.tar.gz \
    "https://github.com/go-task/task/releases/download/${TASK_VERSION}/task_linux_${ARCH}.tar.gz"
  tar -xzf /tmp/task.tar.gz -C /usr/local/bin task
  chmod +x /usr/local/bin/task && rm /tmp/task.tar.gz
  ok "Task installed ($(task --version))"
fi

# ── step-cli (optional) ───────────────────────────────────────────────────────
header "step-cli (optional -- JWT inspection, mTLS)"
STEP_VERSION="0.25.2"
if command -v step &>/dev/null; then
  ok "step already installed -- skipping"
else
  info "Installing step-cli ${STEP_VERSION}..."
  STEP_ARCH="amd64"; [[ "$ARCH" == "arm64" ]] && STEP_ARCH="arm64"
  curl -fsSLo /tmp/step.deb \
    "https://dl.smallstep.com/gh-release/cli/gh-release-header/v${STEP_VERSION}/step-cli_${STEP_VERSION}_${STEP_ARCH}.deb"
  dpkg -i /tmp/step.deb && rm /tmp/step.deb
  ok "step installed"
fi

# ── Cilium CLI (optional) ─────────────────────────────────────────────────────
header "Cilium CLI (optional -- CNI=cilium only)"
CILIUM_VERSION="v0.16.4"
if command -v cilium &>/dev/null; then
  ok "cilium CLI already installed -- skipping"
else
  info "Installing Cilium CLI ${CILIUM_VERSION}..."
  curl -fsSLo /tmp/cilium.tar.gz \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_VERSION}/cilium-linux-${ARCH}.tar.gz"
  tar -xzf /tmp/cilium.tar.gz -C /usr/local/bin && rm /tmp/cilium.tar.gz
  ok "Cilium CLI installed"
fi

# ── Kernel settings ───────────────────────────────────────────────────────────
header "Kernel / network settings"
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p /etc/sysctl.conf >/dev/null
  ok "IP forwarding enabled"
else
  ok "IP forwarding already enabled"
fi

if ! grep -q "fs.inotify.max_user_watches" /etc/sysctl.conf 2>/dev/null; then
  printf "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512\n" >> /etc/sysctl.conf
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
for tool in docker kubectl k3d helm helmfile task; do
  command -v "$tool" &>/dev/null && printf "    %-12s %s\n" "$tool" "$(command -v $tool)"
done
echo ""
if [[ -n "${REAL_USER:-}" ]] && ! groups "$REAL_USER" 2>/dev/null | grep -q docker; then
  echo -e "${YELLOW}  ACTION REQUIRED: newgrp docker (or log out/in)${NC}"
  echo ""
fi
echo -e "  Next steps:"
echo -e "    ${CYAN}task check${NC}   -- verify all tools"
echo -e "    ${CYAN}task up${NC}      -- spin up the full lab"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""