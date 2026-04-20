#!/usr/bin/env bash
# scripts/resolve-ingress-ip.sh
# Resolves the NGINX Ingress Controller ClusterIP at runtime and returns a
# patched job manifest with the correct hostAliases IP.
#
# Usage (called by Taskfile):
#   RESOLVED=$(bash scripts/resolve-ingress-ip.sh jobs/gotestwaf-job.yaml)
#   kubectl apply -f "$RESOLVED"
#
# The script writes a resolved copy to /tmp and prints the path on stdout.
# Any informational/diagnostic output goes to stderr, so stdout stays clean
# for the Taskfile capture.
#
# Service discovery strategy (in order):
#   1. Label selector app.kubernetes.io/name=nginx-ingress  -- robust across
#      chart versions and release names.
#   2. Common service names: nginx-ingress, nginx-ingress-controller.
#   3. Hard error listing what IS present in the namespace.
set -euo pipefail

JOB_FILE="${1:-}"
PLACEHOLDER="${2:-INGRESS_IP_PLACEHOLDER}"
NS="${INGRESS_NAMESPACE:-nginx-ingress}"

if [[ -z "$JOB_FILE" ]]; then
  echo "Usage: $0 <job-yaml-file> [placeholder]" >&2
  exit 1
fi

if [[ ! -f "$JOB_FILE" ]]; then
  echo "ERROR: $JOB_FILE not found" >&2
  exit 1
fi

# ── Resolve the ingress service ClusterIP ─────────────────────────────────
INGRESS_IP=""
INGRESS_SVC=""

# 1. Preferred: label selector (works regardless of release/chart name)
INGRESS_SVC=$(kubectl get svc -n "$NS" \
  -l app.kubernetes.io/name=nginx-ingress \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$INGRESS_SVC" ]]; then
  INGRESS_IP=$(kubectl get svc "$INGRESS_SVC" -n "$NS" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
fi

# 2. Fallback: common service names
if [[ -z "$INGRESS_IP" || "$INGRESS_IP" == "None" ]]; then
  for candidate in nginx-ingress nginx-ingress-controller; do
    IP=$(kubectl get svc "$candidate" -n "$NS" \
      -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -n "$IP" && "$IP" != "None" ]]; then
      INGRESS_SVC="$candidate"
      INGRESS_IP="$IP"
      break
    fi
  done
fi

# 3. Still nothing -- fail loudly with actionable context
if [[ -z "$INGRESS_IP" || "$INGRESS_IP" == "None" ]]; then
  echo "ERROR: Could not resolve NGINX Ingress Controller service in namespace '$NS'." >&2
  echo "       Tried: label app.kubernetes.io/name=nginx-ingress," >&2
  echo "              names nginx-ingress, nginx-ingress-controller." >&2
  echo "" >&2
  echo "       Services present in '$NS':" >&2
  kubectl get svc -n "$NS" 2>&1 | sed 's/^/         /' >&2 || true
  echo "" >&2
  echo "       If the cluster isn't running: task up" >&2
  exit 1
fi

# ── Patch the job manifest ────────────────────────────────────────────────
RESOLVED="/tmp/$(basename "$JOB_FILE" .yaml)-resolved.yaml"
sed "s|${PLACEHOLDER}|${INGRESS_IP}|g" "$JOB_FILE" > "$RESOLVED"

echo "Resolved $PLACEHOLDER -> $INGRESS_IP (svc/$INGRESS_SVC) in $(basename "$JOB_FILE")" >&2
echo "$RESOLVED"
