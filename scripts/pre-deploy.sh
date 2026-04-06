#!/usr/bin/env bash
# scripts/pre-deploy.sh
# Creates resources that Helm charts depend on but don't create themselves.
# Reads hostnames from lab.env to generate correct TLS certificates and ingress.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load lab config and secrets safely
# Handles special characters in values (JWT tokens, passwords etc.)
load_lab_env() {
  local env_file="${1}"
  local secrets_file="$(dirname "${env_file}")/lab.secrets"

  if [ ! -f "${env_file}" ]; then
    echo "ERROR: ${env_file} not found"; exit 1
  fi

  # Parse key=value, skip comments and blanks
  _parse_env() {
    local file="${1}"
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "${line}" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// }" ]] && continue
      local key="${line%%=*}"
      local value="${line#*=}"
      value="${value%%#*}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      [[ "${value}" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
      [[ "${value}" =~ ^\"(.*)\"$ ]] && value="${BASH_REMATCH[1]}"
      export "${key}=${value}" 2>/dev/null || true
    done < "${file}"
  }

  _parse_env "${env_file}"

  # Load secrets if present
  if [ -f "${secrets_file}" ]; then
    _parse_env "${secrets_file}"
  fi

  # Resolve hostnames from LAB_DOMAIN
  export CRAPI_HOST="crapi.${LAB_DOMAIN}"
  export JUICESHOP_HOST="juiceshop.${LAB_DOMAIN}"
  export DVGA_HOST="dvga.${LAB_DOMAIN}"
  export VAMPI_HOST="vampi.${LAB_DOMAIN}"
}


load_lab_env "${SCRIPT_DIR}/../lab.env"

echo "Creating namespaces..."
for ns in cert-manager nginx-ingress monitoring crapi juice-shop dvga vampi; do
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
            base/vampi/ingress.yaml base/vampi/certificate.yaml; do
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
echo "  https://${VAMPI_HOST}"
