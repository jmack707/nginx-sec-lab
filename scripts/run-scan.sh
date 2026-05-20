#!/usr/bin/env bash
# scripts/run-scan.sh <scanner>
# scanner: gotestwaf | nuclei
set -euo pipefail

SCANNER="${1:-gotestwaf}"
RESULTS_DIR="./results"
mkdir -p "$RESULTS_DIR"

kubectl apply -f jobs/results-pvc.yaml

case "$SCANNER" in
  gotestwaf)
    JOB_FILE="jobs/gotestwaf-job.yaml"
    JOB_NAME="gotestwaf-scan"
    TIMEOUT="900s"
    ;;
  nuclei)
    JOB_FILE="jobs/nuclei-job.yaml"
    JOB_NAME="nuclei-scan"
    TIMEOUT="1200s"
    ;;
  *)
    echo "ERROR: Unknown scanner '$SCANNER'. Use: gotestwaf | nuclei"
    exit 1
    ;;
esac

echo "Starting $SCANNER scan..."
kubectl delete job "$JOB_NAME" --ignore-not-found=true

RESOLVED=$(bash scripts/resolve-ingress-ip.sh "$JOB_FILE")
kubectl apply -f "$RESOLVED"

kubectl wait --for=condition=complete "job/${JOB_NAME}" --timeout="$TIMEOUT"

TS=$(date +%Y%m%d-%H%M%S)
OUTPUT="${RESULTS_DIR}/${SCANNER}-${TS}.txt"
kubectl logs "job/${JOB_NAME}" | tee "$OUTPUT"
echo ""
echo "Scan complete. Results saved to: $OUTPUT"
