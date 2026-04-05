#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-nginx-sec-lab}"

echo "Creating k3d cluster: ${CLUSTER_NAME}..."
k3d cluster create "${CLUSTER_NAME}" \
  --servers 1 \
  --agents 2 \
  --port "80:80@loadbalancer" \
  --port "443:443@loadbalancer" \
  --port "8443:8443@loadbalancer" \
  --port "8080:8080@loadbalancer" \
  --port "9000:9000@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

echo "Waiting for nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
echo "Cluster ready"
