#!/usr/bin/env bash
set -euo pipefail
CNI="${CNI:-kindnet}"
case "$CNI" in
  kindnet)
    echo "kindnet is built into kind -- no install needed"
    ;;
  cilium)
    bash scripts/install-cilium.sh
    ;;
  flannel)
    echo "ERROR: Flannel support not yet implemented. See cni/flannel/README.md"
    exit 1
    ;;
  *)
    echo "ERROR: Unknown CNI '$CNI'. Supported: kindnet, cilium"
    exit 1
    ;;
esac
