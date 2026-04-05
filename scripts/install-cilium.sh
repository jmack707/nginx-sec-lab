#!/usr/bin/env bash
# scripts/install-cilium.sh
# Installs Cilium CNI into the running kind cluster.
# Called by: task cni:install CNI=cilium
#
# Environment variables (all optional, have defaults):
#   MODE             base (default) | bigip
#   BIGIP_VTEP_IP    BIG-IP tunnel self-IP    (bigip mode only)
#   BIGIP_VTEP_CIDR  BIG-IP tunnel subnet     (bigip mode only)
#   BIGIP_VTEP_MASK  BIG-IP tunnel mask       (bigip mode only)
#   BIGIP_VTEP_MAC   BIG-IP tunnel MAC addr   (bigip mode only)
set -euo pipefail

MODE="${MODE:-base}"
BIGIP_VTEP_IP="${BIGIP_VTEP_IP:-10.1.6.1}"
BIGIP_VTEP_CIDR="${BIGIP_VTEP_CIDR:-10.1.6.0/24}"
BIGIP_VTEP_MASK="${BIGIP_VTEP_MASK:-255.255.255.0}"
BIGIP_VTEP_MAC="${BIGIP_VTEP_MAC:-00:00:00:00:00:00}"

echo "Installing Cilium CNI (mode: $MODE)"

helm repo add cilium https://helm.cilium.io/ --force-update 2>/dev/null
helm repo update cilium 2>/dev/null

if [ "$MODE" = "bigip" ]; then
  echo "  VTEP IP:   $BIGIP_VTEP_IP"
  echo "  VTEP CIDR: $BIGIP_VTEP_CIDR"
  echo "  VTEP MAC:  $BIGIP_VTEP_MAC"

  # Substitute placeholders and write resolved values file
  sed \
    -e "s|BIGIP_VTEP_IP_PLACEHOLDER|${BIGIP_VTEP_IP}|g" \
    -e "s|BIGIP_VTEP_CIDR_PLACEHOLDER|${BIGIP_VTEP_CIDR}|g" \
    -e "s|BIGIP_VTEP_MAC_PLACEHOLDER|${BIGIP_VTEP_MAC}|g" \
    cni/cilium/values-bigip.yaml > /tmp/cilium-bigip-resolved.yaml

  helm install cilium cilium/cilium \
    --namespace kube-system \
    --version ">=1.14" \
    -f cni/cilium/values-base.yaml \
    -f /tmp/cilium-bigip-resolved.yaml
else
  helm install cilium cilium/cilium \
    --namespace kube-system \
    --version ">=1.14" \
    -f cni/cilium/values-base.yaml
fi

echo "Waiting for Cilium pods..."
kubectl wait --for=condition=Ready pods \
  -l k8s-app=cilium \
  -n kube-system \
  --timeout=180s

echo "Waiting for nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo "Cilium installed"
