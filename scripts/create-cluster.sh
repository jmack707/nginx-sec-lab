#!/usr/bin/env bash
# scripts/create-cluster.sh
# Creates a k3d cluster using settings from lab.env.
# Binds LoadBalancer ports to LAB_HOST_IP for external client access.
set -euo pipefail

# Load lab config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lab.env"

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
echo ""
echo "External access:"
echo "  http://${LAB_HOST_IP}   https://${LAB_HOST_IP}"
echo "  Add to client /etc/hosts:"
echo "  ${LAB_HOST_IP}  ${CRAPI_HOST} ${JUICESHOP_HOST} ${DVGA_HOST} ${VAPI_HOST}"
