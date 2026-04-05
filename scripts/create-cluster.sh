#!/usr/bin/env bash
# scripts/create-cluster.sh
# Creates a k3d cluster for nginx-sec-lab.
# k3d wraps k3s in Docker — includes a built-in LoadBalancer that maps
# host ports directly (no MetalLB needed).
#
# CNI env var:
#   kindnet  (default) -- use k3s built-in flannel CNI
#   cilium            -- disable flannel so Cilium can be installed
set -euo pipefail

CNI="${CNI:-kindnet}"
CLUSTER_NAME="${CLUSTER_NAME:-nginx-sec-lab}"

if [ "$CNI" = "cilium" ]; then
  echo "Creating k3d cluster with flannel disabled (Cilium will be installed next)..."
  k3d cluster create "${CLUSTER_NAME}" \
    --servers 1 \
    --agents 2 \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0" \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    --wait
  echo "Nodes will be NotReady until Cilium installs -- this is expected"
  kubectl wait --for=condition=Ready nodes --all --timeout=30s || true
else
  echo "Creating k3d cluster with k3s flannel CNI..."
  k3d cluster create "${CLUSTER_NAME}" \
    --servers 1 \
    --agents 2 \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0" \
    --wait
  kubectl wait --for=condition=Ready nodes --all --timeout=120s
fi

echo "Cluster ready:"
kubectl get nodes -o wide
