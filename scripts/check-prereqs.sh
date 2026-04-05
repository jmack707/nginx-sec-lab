#!/usr/bin/env bash
# scripts/check-prereqs.sh
# Verifies all prerequisites are installed and meet minimum versions.
# Called by: task check
# Install missing tools: sudo bash scripts/install-ubuntu.sh
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

ver_part() {
  echo "$1" | cut -d. -f"$2" | tr -dc '0-9'
}

check() {
  local name="$1" cmd="$2" version_cmd="$3" min_version="$4" install_hint="$5"

  if ! command -v "$cmd" &>/dev/null; then
    echo -e "  ${RED}MISSING${NC}  $name"
    echo -e "           install: ${CYAN}$install_hint${NC}"
    FAIL=$((FAIL+1))
    return
  fi

  local version
  version=$(eval "$version_cmd" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

  if [[ -z "$version" ]]; then
    echo -e "  ${YELLOW}UNKNOWN${NC}  $name (found but version undetectable)"
    PASS=$((PASS+1))
    return
  fi

  local maj min patch req_maj req_min req_patch
  maj=$(ver_part "$version" 1);         maj=${maj:-0}
  min=$(ver_part "$version" 2);         min=${min:-0}
  patch=$(ver_part "$version" 3);       patch=${patch:-0}
  req_maj=$(ver_part "$min_version" 1); req_maj=${req_maj:-0}
  req_min=$(ver_part "$min_version" 2); req_min=${req_min:-0}
  req_patch=$(ver_part "$min_version" 3); req_patch=${req_patch:-0}

  local ver_int=$(( maj * 10000 + min * 100 + patch ))
  local req_int=$(( req_maj * 10000 + req_min * 100 + req_patch ))

  if (( ver_int >= req_int )); then
    echo -e "  ${GREEN}OK${NC}       $name $version  (min: $min_version)"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}OLD${NC}      $name $version  (min: $min_version)"
    echo -e "           upgrade: ${CYAN}$install_hint${NC}"
    FAIL=$((FAIL+1))
  fi
}

check_port() {
  local port="$1" desc="$2"
  if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
     netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
    echo -e "  ${RED}IN USE${NC}   Port $port ($desc) -- free before 'task cluster'"
    FAIL=$((FAIL+1))
  else
    echo -e "  ${GREEN}FREE${NC}     Port $port ($desc)"
    PASS=$((PASS+1))
  fi
}

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  nginx-sec-lab -- Prerequisite Check${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo "HOST"
if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  UBUNTU_VER=$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"')
  echo -e "  ${GREEN}OK${NC}       Ubuntu $UBUNTU_VER"
  PASS=$((PASS+1))
else
  OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "Unknown")
  echo -e "  ${YELLOW}WARN${NC}     OS: $OS (Ubuntu 22.04/24.04 recommended)"
fi

echo ""
echo "REQUIRED TOOLS"

check "Docker Engine" "docker" \
  "docker version --format '{{.Server.Version}}'" \
  "20.10" "sudo bash scripts/install-ubuntu.sh"

check "kubectl" "kubectl" \
  "kubectl version --client -o json 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['clientVersion']['gitVersion'].lstrip('v'))\"" \
  "1.28" "sudo bash scripts/install-ubuntu.sh"

check "k3d" "k3d" \
  "k3d version" \
  "5.6" "sudo bash scripts/install-ubuntu.sh"

check "helm" "helm" \
  "helm version --short" \
  "3.13" "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

check "helmfile" "helmfile" \
  "helmfile version" \
  "0.160" "sudo bash scripts/install-ubuntu.sh"

check "task" "task" \
  "task --version" \
  "3.30" "sudo bash scripts/install-ubuntu.sh"

check "git" "git" \
  "git --version" \
  "2.30" "sudo apt-get install -y git"

echo ""
echo "HELM PLUGINS"
if command -v helm &>/dev/null && helm plugin list 2>/dev/null | grep -q "diff"; then
  echo -e "  ${GREEN}OK${NC}       helm-diff (required by helmfile)"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}MISSING${NC}  helm-diff"
  echo -e "           install: ${CYAN}helm plugin install https://github.com/databus23/helm-diff${NC}"
  FAIL=$((FAIL+1))
fi

echo ""
echo "OPTIONAL"

check "step" "step" \
  "step version" \
  "0.24" "sudo bash scripts/install-ubuntu.sh  (JWT inspection and mTLS testing)"

check "cilium CLI" "cilium" \
  "cilium version --client" \
  "0.15" "sudo bash scripts/install-ubuntu.sh  (CNI=cilium only)"

check "python3" "python3" \
  "python3 --version" \
  "3.8" "sudo apt-get install -y python3"

check "jq" "jq" \
  "jq --version" \
  "1.6" "sudo apt-get install -y jq"

echo ""
echo "HOST PORTS  (must be free before 'task cluster')"
check_port 80  "HTTP  -> k3d LoadBalancer"
check_port 443 "HTTPS -> k3d LoadBalancer"

echo ""
echo "DOCKER"
if docker info &>/dev/null; then
  DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
  echo -e "  ${GREEN}OK${NC}       Docker daemon running (v${DOCKER_VER})"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}     Docker daemon not running"
  echo -e "           Run: ${CYAN}sudo systemctl start docker${NC}"
  FAIL=$((FAIL+1))
fi

echo ""
echo "KERNEL"
IP_FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
if [[ "$IP_FWD" == "1" ]]; then
  echo -e "  ${GREEN}OK${NC}       net.ipv4.ip_forward = 1"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}     net.ipv4.ip_forward = 0"
  echo -e "           Fix: ${CYAN}echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p${NC}"
  FAIL=$((FAIL+1))
fi

INOTIFY=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
if (( INOTIFY >= 65536 )); then
  echo -e "  ${GREEN}OK${NC}       fs.inotify.max_user_watches = ${INOTIFY}"
  PASS=$((PASS+1))
else
  echo -e "  ${YELLOW}LOW${NC}      fs.inotify.max_user_watches = ${INOTIFY} (recommend >= 524288)"
  echo -e "           Fix: ${CYAN}sudo bash scripts/install-ubuntu.sh${NC}"
fi

echo ""
echo "LOCAL CA"
if [[ -f "root_ca.crt" && -f "root_ca.key" ]]; then
  echo -e "  ${GREEN}OK${NC}       root_ca.crt and root_ca.key found"
  PASS=$((PASS+1))
else
  echo -e "  ${YELLOW}WARN${NC}     root_ca.crt / root_ca.key not found (created automatically by task up)"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if (( FAIL == 0 )); then
  echo -e "  ${GREEN}ALL CHECKS PASSED${NC}  ($PASS passed)"
  echo -e "  Ready to run: ${CYAN}task up${NC}"
else
  echo -e "  ${RED}${FAIL} CHECK(S) FAILED${NC}  ($PASS passed, $FAIL failed)"
  echo -e "  Run ${CYAN}sudo bash scripts/install-ubuntu.sh${NC} to fix missing tools."
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

exit $FAIL
