#!/usr/bin/env bash
set -euo pipefail
CIS_MODE="${CIS_MODE:-nodeport}"
echo "Installing BIG-IP CIS in ${CIS_MODE} mode..."
helm repo add f5-stable https://f5networks.github.io/charts/stable --force-update
helm repo update f5-stable
helm install f5-bigip-ctlr f5-stable/f5-bigip-ctlr \
  --namespace kube-system \
  -f "values/cis-${CIS_MODE}.yaml"
echo "CIS installed in ${CIS_MODE} mode"
