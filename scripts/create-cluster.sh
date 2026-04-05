#!/usr/bin/env bash
set -euo pipefail
CNI="${CNI:-kindnet}"
if [ "$CNI" = "kindnet" ]; then
  echo "Creating cluster with kindnet CNI..."
  kind create cluster --config kind-config.yaml
  kubectl wait --for=condition=Ready nodes --all --timeout=120s
else
  echo "Creating cluster with CNI disabled (${CNI} will be installed next)..."
  kind create cluster --config kind-config-no-cni.yaml
  kubectl wait --for=condition=Ready nodes --all --timeout=30s || true
fi
echo "Cluster ready"
