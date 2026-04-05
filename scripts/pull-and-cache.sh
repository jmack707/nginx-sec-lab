#!/usr/bin/env bash
# scripts/pull-and-cache.sh
# Pulls all lab images and stores them in the local registry under the exact
# path that containerd expects when using the registry as a docker.io mirror.
#
# Official Docker Hub images (no org prefix) must be stored under library/:
#   busybox:1.35   -> k3d-registry.localhost:5000/library/busybox:1.35
#   mongo:4.4      -> k3d-registry.localhost:5000/library/mongo:4.4
#
# Org images keep their full path:
#   nginx/nginx-ingress:3.4.3 -> k3d-registry.localhost:5000/nginx/nginx-ingress:3.4.3
#
# quay.io images include the registry prefix:
#   quay.io/jetstack/cert-manager-controller:v1.14.7
#     -> k3d-registry.localhost:5000/quay.io/jetstack/cert-manager-controller:v1.14.7
set -euo pipefail

REGISTRY="k3d-registry.localhost:5000"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
info() { echo -e "  ${CYAN}→${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; }

cache() {
  # cache <full-image-ref> <registry-path>
  # full-image-ref: what to pull  (e.g. busybox:1.35)
  # registry-path:  path in local registry (e.g. library/busybox:1.35)
  local src="$1"
  local dst="$2"
  local local_tag="${REGISTRY}/${dst}"

  # Extract repo and tag from dst for API check
  local repo="${dst%%:*}"
  local tag="${dst##*:}"
  [[ "$dst" != *":"* ]] && tag="latest"

  if curl -sf "http://${REGISTRY}/v2/${repo}/tags/list" 2>/dev/null \
      | grep -q "\"${tag}\""; then
    ok "Already cached: ${src}"
    return
  fi

  info "Pulling ${src}..."
  if docker pull "${src}" --quiet 2>/dev/null; then
    docker tag "${src}" "${local_tag}"
    docker push "${local_tag}" --quiet 2>/dev/null \
      && ok "Cached: ${src} -> ${dst}" \
      || fail "Push failed: ${src}"
  else
    fail "Pull failed: ${src}"
  fi
}

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  nginx-sec-lab -- Image Cache${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if ! docker inspect k3d-registry.localhost &>/dev/null; then
  echo -e "${RED}ERROR: Registry not running. Run: task registry:setup${NC}"
  exit 1
fi

echo "INFRASTRUCTURE"
# quay.io images - include registry prefix in path
cache "quay.io/jetstack/cert-manager-controller:v1.14.7"  "quay.io/jetstack/cert-manager-controller:v1.14.7"
cache "quay.io/jetstack/cert-manager-cainjector:v1.14.7"  "quay.io/jetstack/cert-manager-cainjector:v1.14.7"
cache "quay.io/jetstack/cert-manager-webhook:v1.14.7"     "quay.io/jetstack/cert-manager-webhook:v1.14.7"
cache "quay.io/kiwigrid/k8s-sidecar:1.26.1"               "quay.io/kiwigrid/k8s-sidecar:1.26.1"
cache "quay.io/prometheus/prometheus:v2.50.1"              "quay.io/prometheus/prometheus:v2.50.1"
# docker.io org images - keep org/image path
cache "nginx/nginx-ingress:3.4.3"   "nginx/nginx-ingress:3.4.3"
cache "grafana/grafana:10.4.0"      "grafana/grafana:10.4.0"
cache "prom/node-exporter:latest"   "prom/node-exporter:latest"

echo ""
echo "DEMO APPS"
# docker.io org images
cache "crapi/crapi-identity:latest"   "crapi/crapi-identity:latest"
cache "crapi/crapi-community:latest"  "crapi/crapi-community:latest"
cache "crapi/crapi-workshop:latest"   "crapi/crapi-workshop:latest"
cache "crapi/crapi-web:latest"        "crapi/crapi-web:latest"
cache "mailhog/mailhog:latest"        "mailhog/mailhog:latest"
cache "bkimminich/juice-shop:latest"  "bkimminich/juice-shop:latest"
cache "dolevf/dvga:latest"            "dolevf/dvga:latest"
cache "roottusk/vapi:latest"          "roottusk/vapi:latest"
cache "curlimages/curl:latest"        "curlimages/curl:latest"
# docker.io official (library) images - MUST use library/ prefix
cache "busybox:1.35"       "library/busybox:1.35"
cache "mongo:4.4"          "library/mongo:4.4"
cache "postgres:14-alpine" "library/postgres:14-alpine"
cache "mariadb:10.6"       "library/mariadb:10.6"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Cache complete. Run 'task down && task up' to use cached images.${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
