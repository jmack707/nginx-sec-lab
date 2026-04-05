#!/usr/bin/env bash
set -euo pipefail
if kubectl get ds -n kube-system cilium &>/dev/null; then
  echo "=== Cilium Status ==="
  kubectl exec -n kube-system ds/cilium -- cilium status --brief
  echo ""
  echo "=== VTEP Entries ==="
  kubectl exec -n kube-system ds/cilium -- cilium bpf vtep list 2>/dev/null \
    || echo "(No VTEP entries -- base mode)"
else
  echo "Cilium not installed -- CNI: kindnet or flannel"
fi
echo ""
echo "=== Nodes ==="
kubectl get nodes -o wide
