#!/usr/bin/env bash
# scripts/resolve-ingress-ip.sh
# Resolves the NGINX Ingress Controller ClusterIP at runtime and
# returns a patched job manifest with the correct hostAliases IP.
#
# Usage (called by Taskfile):
#   RESOLVED=$(bash scripts/resolve-ingress-ip.sh jobs/gotestwaf-job.yaml)
#   kubectl apply -f "$RESOLVED"
#
# The script writes a resolved copy to /tmp and prints the path.
# The INGRESS_IP placeholder in job YAMLs is replaced with the real ClusterIP.

set -euo pipefail

JOB_FILE="${1:-}"
PLACEHOLDER="${2:-INGRESS_IP_PLACEHOLDER}"

if [[ -z "$JOB_FILE" ]]; then
  echo "Usage: $0 <job-yaml-file> [placeholder]" >&2
  exit 1
fi

if [[ ! -f "$JOB_FILE" ]]; then
  echo "ERROR: $JOB_FILE not found" >&2
  exit 1
fi

# Resolve NGINX Ingress ClusterIP
INGRESS_IP=$(kubectl get svc nginx-ingress \
  -n nginx-ingress \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

if [[ -z "$INGRESS_IP" ]]; then
  echo "ERROR: Could not resolve nginx-ingress service ClusterIP." >&2
  echo "       Is the cluster running? Try: kubectl get svc -n nginx-ingress" >&2
  exit 1
fi

# Write resolved copy to /tmp
RESOLVED="/tmp/$(basename "$JOB_FILE" .yaml)-resolved.yaml"
sed "s|${PLACEHOLDER}|${INGRESS_IP}|g" "$JOB_FILE" > "$RESOLVED"

echo "Resolved $PLACEHOLDER → $INGRESS_IP in $(basename "$JOB_FILE")" >&2
echo "$RESOLVED"
