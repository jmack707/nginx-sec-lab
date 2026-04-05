#!/usr/bin/env bash
# Create resources that helm charts depend on but don't create themselves
set -euo pipefail

echo "  Creating monitoring namespace and Grafana dashboard configmap..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap nginx-lab-dashboard \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  Creating nginx-ingress namespace and default TLS secret..."
kubectl create namespace nginx-ingress --dry-run=client -o yaml | kubectl apply -f -
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/nginx-default.key \
  -out /tmp/nginx-default.crt \
  -subj "/CN=nginx-default/O=nginx-sec-lab" 2>/dev/null
kubectl create secret tls default-server-secret \
  --cert=/tmp/nginx-default.crt \
  --key=/tmp/nginx-default.key \
  --namespace nginx-ingress \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/nginx-default.key /tmp/nginx-default.crt

echo "  Pre-deploy resources ready."
