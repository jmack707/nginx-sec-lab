#!/usr/bin/env bash
# scripts/import-images.sh
# Imports single-arch images from Docker's local cache into k3d cluster nodes.
# Multi-arch images (nginx, grafana etc.) are served by the registry mirror.
# Called by: task images:import
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-nginx-sec-lab}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
info() { echo -e "  ${CYAN}→${NC}  $*"; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }

# These are single-arch images safe to import via k3d image import.
# Multi-arch images (nginx-ingress, grafana, cert-manager etc.) are
# handled by the registry mirror configured in registries.yaml.
IMPORTABLE=(
  "crapi/crapi-identity:latest"
  "crapi/crapi-community:latest"
  "crapi/crapi-workshop:latest"
  "crapi/crapi-web:latest"
  "mongo:4.4"
  "postgres:14-alpine"
  "mailhog/mailhog:latest"
  "bkimminich/juice-shop:latest"
  "dolevf/dvga:latest"
  "erev0s/vampi:latest"
  "mariadb:10.6"
)

echo ""
echo -e "${CYAN}Importing images into cluster '${CLUSTER_NAME}'...${NC}"

PRESENT=()
MISSING=()
for img in "${IMPORTABLE[@]}"; do
  if docker image inspect "$img" &>/dev/null 2>&1; then
    PRESENT+=("$img")
  else
    MISSING+=("$img")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  warn "Not in local cache (will pull from internet or registry mirror):"
  for img in "${MISSING[@]}"; do echo "    $img"; done
fi

if [ ${#PRESENT[@]} -gt 0 ]; then
  info "Importing ${#PRESENT[@]} images..."
  k3d image import "${PRESENT[@]}" -c "${CLUSTER_NAME}" 2>/dev/null \
    && ok "Imported ${#PRESENT[@]} images" \
    || warn "Some imports had warnings -- usually safe to ignore"
fi

echo ""
