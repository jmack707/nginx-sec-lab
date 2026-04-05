#!/usr/bin/env bash
set -euo pipefail

echo "Seeding crAPI test users..."
kubectl delete job crapi-seed -n crapi --ignore-not-found=true
kubectl apply -f jobs/crapi-seed-job.yaml
kubectl wait --for=condition=complete job/crapi-seed -n crapi --timeout=120s
kubectl logs job/crapi-seed -n crapi
echo "Users seeded"

echo ""
echo "Starting Locust traffic generation..."
mkdir -p ./results
kubectl apply -f jobs/results-pvc.yaml
kubectl delete job locust-traffic --ignore-not-found=true
kubectl delete configmap locust-script --ignore-not-found=true

RESOLVED=$(bash scripts/resolve-ingress-ip.sh jobs/locust-job.yaml)
kubectl apply -f "$RESOLVED"

echo "Locust started. Follow logs with: task locust:logs"
