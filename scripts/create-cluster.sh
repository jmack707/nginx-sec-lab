#!/usr/bin/env bash
# scripts/create-cluster.sh
# Creates a k3d cluster using settings from lab.env.
# Binds LoadBalancer ports to LAB_HOST_IP for external client access.
set -euo pipefail

# ── Pre-flight: clean up any stale NAT rules ─────────────────────────────
# Rogue PREROUTING DNAT rules from previous deployments will silently
# intercept all port 80/443 traffic before k3d rules run.
# Check and remove any rules not created by this cluster.
echo "Checking for stale NAT rules..."
STALE=$(sudo iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null   | awk '/DNAT.*dpt:(80|443)/ && !/172\.19\.|172\.16\./ {print $1}'   | sort -rn)
if [ -n "$STALE" ]; then
  echo "  WARNING: Found stale DNAT rules -- removing:"
  for num in $STALE; do
    rule=$(sudo iptables -t nat -L PREROUTING -n --line-numbers | grep "^${num} ")
    echo "    Removing: $rule"
    sudo iptables -t nat -D PREROUTING "$num"
  done
  echo "  Stale rules removed"
else
  echo "  No stale rules found"
fi

# Load lab config and secrets safely
# Handles special characters in values (JWT tokens, passwords etc.)
load_lab_env() {
  local env_file="${1}"
  local secrets_file="$(dirname "${env_file}")/lab.secrets"

  if [ ! -f "${env_file}" ]; then
    echo "ERROR: ${env_file} not found"; exit 1
  fi

  # Parse key=value, skip comments and blanks
  _parse_env() {
    local file="${1}"
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "${line}" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// }" ]] && continue
      local key="${line%%=*}"
      local value="${line#*=}"
      value="${value%%#*}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      [[ "${value}" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
      [[ "${value}" =~ ^\"(.*)\"$ ]] && value="${BASH_REMATCH[1]}"
      export "${key}=${value}" 2>/dev/null || true
    done < "${file}"
  }

  _parse_env "${env_file}"

  # Load secrets if present
  if [ -f "${secrets_file}" ]; then
    _parse_env "${secrets_file}"
  fi

  # Resolve hostnames from LAB_DOMAIN
  export CRAPI_HOST="crapi.${LAB_DOMAIN}"
  export JUICESHOP_HOST="juiceshop.${LAB_DOMAIN}"
  export DVGA_HOST="dvga.${LAB_DOMAIN}"
  export VAMPI_HOST="vampi.${LAB_DOMAIN}"
}


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
load_lab_env "${SCRIPT_DIR}/../lab.env"

REGISTRY_NAME="k3d-registry.localhost"
REGISTRY_PORT="5000"

echo "Lab config:"
echo "  HOST_IP:      ${LAB_HOST_IP}"
echo "  DOMAIN:       ${LAB_DOMAIN}"
echo "  CLUSTER:      ${CLUSTER_NAME}"
echo "  CNI:          ${CNI}"
echo ""

# Build registry args
REGISTRY_ARGS=()
if k3d registry list 2>/dev/null | grep -q "${REGISTRY_NAME}"; then
  echo "Local registry found -- configuring mirror"
  REGISTRY_ARGS+=(--registry-use "${REGISTRY_NAME}:${REGISTRY_PORT}")
  REGISTRY_ARGS+=(--registry-config registries.yaml)
else
  echo "No local registry -- images will pull from internet"
  echo "Run: task registry:setup && task registry:cache"
fi

# Bind to LAB_HOST_IP so external clients can reach the cluster
# Also bind to 127.0.0.1 for local access
BASE_ARGS=(
  --servers 1
  --agents 2
  --port "${LAB_HOST_IP}:80:80@loadbalancer"
  --port "${LAB_HOST_IP}:443:443@loadbalancer"
  --k3s-arg "--disable=traefik@server:0"
)

if [ "${CNI}" = "cilium" ]; then
  echo "Creating cluster (Cilium -- flannel disabled)..."
  k3d cluster create "${CLUSTER_NAME}" \
    "${BASE_ARGS[@]}" \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    "${REGISTRY_ARGS[@]}" \
    --wait
  kubectl wait --for=condition=Ready nodes --all --timeout=30s || true
else
  echo "Creating cluster (k3s flannel)..."
  k3d cluster create "${CLUSTER_NAME}" \
    "${BASE_ARGS[@]}" \
    "${REGISTRY_ARGS[@]}" \
    --wait
  kubectl wait --for=condition=Ready nodes --all --timeout=120s
fi

echo ""
echo "Cluster ready:"
kubectl get nodes -o wide
# Allow externally-routed traffic through Docker's FORWARD chain.
# Docker sets FORWARD policy to DROP and only adds rules for its own bridge.
# Traffic arriving on ens18 (external clients) needs explicit acceptance
# in DOCKER-USER which is checked before Docker's own rules.
PRIMARY_IF=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || echo "ens18")
echo "Adding DOCKER-USER FORWARD rule for ${PRIMARY_IF}..."
if ! sudo iptables -C DOCKER-USER -i "${PRIMARY_IF}" -j ACCEPT 2>/dev/null; then
  sudo iptables -I DOCKER-USER -i "${PRIMARY_IF}" -j ACCEPT
  echo "  Rule added -- external clients can now reach the cluster"
else
  echo "  Rule already present"
fi

echo ""
echo "External access:"
echo "  http://${LAB_HOST_IP}   https://${LAB_HOST_IP}"
echo "  Add to client /etc/hosts:"
echo "  ${LAB_HOST_IP}  ${CRAPI_HOST} ${JUICESHOP_HOST} ${DVGA_HOST} ${VAMPI_HOST}"
