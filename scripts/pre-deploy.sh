#!/usr/bin/env bash
# scripts/pre-deploy.sh
# Creates resources that Helm charts depend on but don't create themselves.
# Reads hostnames and app list from lab.env to generate correct TLS certificates
# and ingress, and only touches the apps listed in LAB_APPS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

# Load lab config and secrets safely
# Handles special characters in values (JWT tokens, passwords etc.)
load_lab_env() {
  local env_file="${1}"
  local secrets_file="$(dirname "${env_file}")/lab.secrets"

  if [ ! -f "${env_file}" ]; then
    echo "ERROR: ${env_file} not found"; exit 1
  fi

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

# Resource defaults
LAB_APPS="${LAB_APPS:-crapi juiceshop dvga vampi}"
VALID_APPS="crapi juiceshop dvga vampi"

# Map app key -> namespace (juiceshop -> juice-shop, others identical)
app_ns() {
  case "$1" in
    juiceshop) echo "juice-shop" ;;
    *)         echo "$1" ;;
  esac
}

# Build the list of selected apps + their namespaces, validating as we go
SELECTED_APPS=""
SELECTED_NS=""
for app in ${LAB_APPS//,/ }; do
  if ! [[ " ${VALID_APPS} " == *" ${app} "* ]]; then
    echo "WARN: unknown app '${app}' in LAB_APPS -- skipping (valid: ${VALID_APPS})"
    continue
  fi
  SELECTED_APPS="${SELECTED_APPS} ${app}"
  SELECTED_NS="${SELECTED_NS} $(app_ns "${app}")"
done
SELECTED_APPS="${SELECTED_APPS# }"
SELECTED_NS="${SELECTED_NS# }"

if [ -z "${SELECTED_APPS}" ]; then
  echo "ERROR: LAB_APPS is empty or contains no valid apps"
  exit 1
fi

echo "Selected apps:       ${SELECTED_APPS}"
echo "Selected namespaces: ${SELECTED_NS}"
echo ""

echo "Creating infrastructure namespaces..."
for ns in cert-manager nginx-ingress monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo "Creating selected app namespaces..."
for ns in ${SELECTED_NS}; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo "Creating default-server-secret for NGINX Ingress..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /tmp/nginx-default.key \
  -out /tmp/nginx-default.crt \
  -subj "/CN=nginx-default/O=${CLUSTER_NAME:-nginx-sec-lab}" 2>/dev/null
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

# Patch ingress + certificate hostnames for ONLY the selected apps.
# Self-healing: rewrites whatever domain is currently in the file to LAB_DOMAIN,
# so the base files can hold any prior domain (lab.local, 1broken.net, etc.)
# without breaking subsequent runs.
echo "Patching ingress hostnames for domain: ${LAB_DOMAIN} (apps: ${SELECTED_APPS})..."
for app in ${SELECTED_APPS}; do
  for f in "${REPO_DIR}/base/${app}/ingress.yaml" \
           "${REPO_DIR}/base/${app}/certificate.yaml"; do
    if [ ! -f "$f" ]; then
      echo "  WARN: $f not found -- skipping"
      continue
    fi
    sed -i -E "s/(crapi|juiceshop|dvga|vampi)\.[a-zA-Z0-9.-]+/\1.${LAB_DOMAIN}/g" "$f"
    echo "  patched: ${f#${REPO_DIR}/}"
  done
done

echo ""
echo "Pre-deploy complete."
echo ""
echo "Lab endpoints will be available at:"
for app in ${SELECTED_APPS}; do
  case "$app" in
    crapi)     echo "  https://${CRAPI_HOST}" ;;
    juiceshop) echo "  https://${JUICESHOP_HOST}" ;;
    dvga)      echo "  https://${DVGA_HOST}" ;;
    vampi)     echo "  https://${VAMPI_HOST}" ;;
  esac
done