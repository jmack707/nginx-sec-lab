#!/usr/bin/env bash
# scripts/pre-deploy.sh
# Creates resources that Helm charts depend on but don't create themselves.
# Reads hostnames from lab.env to generate correct TLS certificates and ingress.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lab.env"

echo "Creating namespaces..."
for ns in cert-manager nginx-ingress monitoring crapi juice-shop dvga vapi; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo "Creating default-server-secret for NGINX Ingress..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /tmp/nginx-default.key \
  -out /tmp/nginx-default.crt \
  -subj "/CN=nginx-default/O=${CLUSTER_NAME}" 2>/dev/null
kubectl create secret tls default-server-secret \
  --cert=/tmp/nginx-default.crt \
  --key=/tmp/nginx-default.key \
  --namespace nginx-ingress \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/nginx-default.key /tmp/nginx-default.crt
echo "  default-server-secret created"

echo "Creating nginx-lab-dashboard ConfigMap for Grafana..."
kubectl apply -f grafana/nginx-dashboard.yaml
echo "  nginx-lab-dashboard created"

# Patch ingress hostnames from lab.env if domain differs from default
if [ "${LAB_DOMAIN}" != "lab.local" ]; then
  echo "Patching ingress hostnames for domain: ${LAB_DOMAIN}..."
  for f in base/crapi/ingress.yaml base/crapi/certificate.yaml \
            base/juiceshop/ingress.yaml base/juiceshop/certificate.yaml \
            base/dvga/ingress.yaml base/dvga/certificate.yaml \
            base/vapi/ingress.yaml base/vapi/certificate.yaml; do
    sed -i "s/\.lab\.local/.${LAB_DOMAIN}/g" "$f"
  done
  echo "  Ingress hostnames updated"
fi

echo "Pre-deploy complete."
echo ""
echo "Lab endpoints will be available at:"
echo "  https://${CRAPI_HOST}"
echo "  https://${JUICESHOP_HOST}"
echo "  https://${DVGA_HOST}"
echo "  https://${VAPI_HOST}"
