#!/usr/bin/env bash
# scripts/install-cni.sh
# k3d uses k3s flannel by default -- no install needed for kindnet mode.
# For CNI=cilium, flannel was disabled at cluster creation time.
set -euo pipefail

CNI="${CNI:-kindnet}"
case "$CNI" in
  kindnet)
    echo "k3d uses k3s flannel by default -- no CNI install needed"
    ;;
  cilium)
    bash scripts/install-cilium.sh
    ;;
  *)
    echo "ERROR: Unknown CNI '$CNI'. Supported: kindnet, cilium"
    exit 1
    ;;
esac
