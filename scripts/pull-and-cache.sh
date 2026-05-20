#!/usr/bin/env bash
# scripts/pull-and-cache.sh
# Pulls all lab images and stores them in the local registry.
# Registry credentials are configured in lab.env.
#
# DOCKERHUB_USER  -- set in lab.env to avoid Docker Hub rate limits
# NGINX_JWT       -- set in lab.env only if using NGINX Plus / App Protect
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

REGISTRY="k3d-registry.localhost:5000"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
info() { echo -e "  ${CYAN}→${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }

# ── Registry login ────────────────────────────────────────────────────────────
login_registries() {
  # Docker Hub
  if [ -n "${DOCKERHUB_USER:-}" ]; then
    if ! cat ~/.docker/config.json 2>/dev/null | grep -q "index.docker.io"; then
      info "Logging in to Docker Hub as ${DOCKERHUB_USER}..."
      if [ -n "${DOCKERHUB_PASS:-}" ]; then
        # Password stored in lab.env
        echo "${DOCKERHUB_PASS}" | docker login --username "${DOCKERHUB_USER}" --password-stdin
      else
        # Prompt interactively (password not stored)
        docker login --username "${DOCKERHUB_USER}"
      fi
      ok "Docker Hub: logged in"
    else
      ok "Docker Hub: already logged in"
    fi
  else
    if ! cat ~/.docker/config.json 2>/dev/null | grep -q "index.docker.io"; then
      warn "DOCKERHUB_USER not set in lab.env -- anonymous pulls may be rate limited"
      warn "Set DOCKERHUB_USER=yourusername in lab.env"
    else
      ok "Docker Hub: already logged in"
    fi
  fi

  # NGINX private registry (Plus/App Protect only)
  if [ "${NGINX_MODE:-oss}" = "plus" ]; then
    if [ -z "${NGINX_JWT:-}" ]; then
      echo -e "${RED}ERROR: NGINX_MODE=plus but NGINX_JWT not set in lab.env${NC}"
      echo "  Get token: https://my.f5.com > My Products > NGINX > Manage Subscriptions"
      echo "  Set NGINX_JWT=<token> in lab.env"
      exit 1
    fi
    if ! cat ~/.docker/config.json 2>/dev/null | grep -q "private-registry.nginx.com"; then
      info "Logging in to NGINX private registry..."
      docker login private-registry.nginx.com \
        --username="${NGINX_JWT}" \
        --password=none
      ok "NGINX private registry: logged in"
    else
      ok "NGINX private registry: already logged in"
    fi
  fi
}

# ── Image caching ─────────────────────────────────────────────────────────────
# cache <src> <dst> [force]
#   force=1 bypasses the "already cached" shortcut and always re-pulls/pushes.
cache() {
  local src="$1" dst="$2" force="${3:-0}"
  local repo="${dst%%:*}" tag="${dst##*:}"
  [[ "$dst" != *":"* ]] && tag="latest"

  if [ "$force" != "1" ] && curl -sf "http://${REGISTRY}/v2/${repo}/tags/list" 2>/dev/null \
      | grep -q "\"${tag}\""; then
    ok "Already cached: ${src}"
    return
  fi

  if [ "$force" = "1" ]; then
    info "Force re-cache: ${src}"
  else
    info "Pulling ${src}..."
  fi

  if docker pull "${src}" --quiet 2>/dev/null; then
    docker tag "${src}" "${REGISTRY}/${dst}"
    docker push "${REGISTRY}/${dst}" --quiet 2>/dev/null \
      && ok "Cached: ${src} → ${REGISTRY}/${dst}" \
      || fail "Push failed: ${src}"
  else
    fail "Pull failed: ${src}"
  fi
}

# ── Determine NGINX image source ──────────────────────────────────────────────
if [ "${NGINX_MODE:-oss}" = "plus" ]; then
  NGINX_IMAGE="private-registry.nginx.com/nginx-ic/nginx-plus-ingress:3.4.3"
  NGINX_DST="nginx-ic/nginx-plus-ingress:3.4.3"
else
  NGINX_IMAGE="nginx/nginx-ingress:3.4.3"
  NGINX_DST="nginx/nginx-ingress:3.4.3"
fi

# ── Main ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  nginx-sec-lab -- Image Cache (mode: ${NGINX_MODE:-oss})${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if ! docker inspect k3d-registry.localhost &>/dev/null; then
  echo -e "${RED}ERROR: Registry not running. Run: task registry:setup${NC}"
  exit 1
fi

login_registries

echo ""
echo "INFRASTRUCTURE"
cache "quay.io/jetstack/cert-manager-controller:v1.14.7"  "quay.io/jetstack/cert-manager-controller:v1.14.7"
cache "quay.io/jetstack/cert-manager-cainjector:v1.14.7"  "quay.io/jetstack/cert-manager-cainjector:v1.14.7"
cache "quay.io/jetstack/cert-manager-webhook:v1.14.7"     "quay.io/jetstack/cert-manager-webhook:v1.14.7"
# Always re-push NIC image so a mode switch can't leave a poisoned manifest.
cache "${NGINX_IMAGE}"                                     "${NGINX_DST}"    1
cache "grafana/grafana:10.4.0"                            "grafana/grafana:10.4.0"
cache "quay.io/kiwigrid/k8s-sidecar:1.26.1"               "quay.io/kiwigrid/k8s-sidecar:1.26.1"
cache "quay.io/prometheus/prometheus:v2.50.1"              "quay.io/prometheus/prometheus:v2.50.1"
cache "prom/node-exporter:latest"                          "prom/node-exporter:latest"

echo ""
echo "DEMO APPS"
cache "crapi/crapi-identity:latest"   "crapi/crapi-identity:latest"
cache "crapi/crapi-community:latest"  "crapi/crapi-community:latest"
cache "crapi/crapi-workshop:latest"   "crapi/crapi-workshop:latest"
cache "crapi/crapi-web:latest"        "crapi/crapi-web:latest"
cache "mailhog/mailhog:latest"        "mailhog/mailhog:latest"
cache "bkimminich/juice-shop:latest"  "bkimminich/juice-shop:latest"
cache "dolevf/dvga:latest"            "dolevf/dvga:latest"
cache "erev0s/vampi:latest"           "erev0s/vampi:latest"
cache "curlimages/curl:latest"        "curlimages/curl:latest"
cache "locustio/locust:latest"        "locustio/locust:latest"
cache "wallarm/gotestwaf:latest"      "wallarm/gotestwaf:latest"
cache "projectdiscovery/nuclei:latest" "projectdiscovery/nuclei:latest"
cache "busybox:1.35"                  "library/busybox:1.35"
cache "mongo:4.4"                     "library/mongo:4.4"
cache "postgres:14-alpine"            "library/postgres:14-alpine"
cache "mariadb:10.6"                  "library/mariadb:10.6"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Cache complete. All images stored in: ${REGISTRY}${NC}"
echo -e "Run ${CYAN}task reset${NC} to rebuild with cached images."
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
