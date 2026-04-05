#!/usr/bin/env bash
set -euo pipefail
MODE="${MODE:-base}"
if [ "$MODE" = "bigip" ]; then
  sed \
    -e "s|BIGIP_VTEP_IP_PLACEHOLDER|${BIGIP_VTEP_IP:-10.1.6.1}|g" \
    -e "s|BIGIP_VTEP_CIDR_PLACEHOLDER|${BIGIP_VTEP_CIDR:-10.1.6.0/24}|g" \
    -e "s|BIGIP_VTEP_MAC_PLACEHOLDER|${BIGIP_VTEP_MAC:-00:00:00:00:00:00}|g" \
    cni/cilium/values-bigip.yaml > /tmp/cilium-bigip-resolved.yaml
  helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    -f cni/cilium/values-base.yaml \
    -f /tmp/cilium-bigip-resolved.yaml
else
  helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    -f cni/cilium/values-base.yaml
fi
echo "Cilium upgraded"
