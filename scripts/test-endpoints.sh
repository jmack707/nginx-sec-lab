#!/usr/bin/env bash
# scripts/test-endpoints.sh
# Smoke test all lab endpoints. Reads config from lab.env.
# Usage: bash scripts/test-endpoints.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lab.env"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; }
info() { echo -e "  ${CYAN}$*${NC}"; }

check() {
  local desc="$1" host="$2" path="${3:-/}" expected="${4:-200}"
  local status
  status=$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve "${host}:443:${LAB_HOST_IP}" \
    "https://${host}${path}" 2>/dev/null || echo "ERR")
  if [[ "$status" == "$expected" ]]; then
    ok "$desc  →  HTTP $status"
  else
    fail "$desc  →  HTTP $status (expected $expected)"
  fi
}

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  nginx-sec-lab endpoint tests (${LAB_HOST_IP})${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo "AVAILABILITY"
check "crAPI"      "${CRAPI_HOST}"     "/" "200"
check "Juice Shop" "${JUICESHOP_HOST}" "/" "200"
check "DVGA"       "${DVGA_HOST}"      "/" "200"
check "vAPI"       "${VAPI_HOST}"      "/" "200"

echo ""
echo "crAPI API"
check "Health check"   "${CRAPI_HOST}" "/identity/health_check"   "200"
check "Login endpoint" "${CRAPI_HOST}" "/identity/api/auth/login" "405"
check "JWKS"           "${CRAPI_HOST}" "/.well-known/jwks.json"   "200"
check "Community (401)" "${CRAPI_HOST}" "/community/api/v2/community/posts/recent" "401"
check "Workshop (401)"  "${CRAPI_HOST}" "/workshop/api/shop/products" "401"

echo ""
echo "JUICE SHOP API"
check "Products" "${JUICESHOP_HOST}" "/rest/products/search?q=" "200"

echo ""
echo "DVGA GRAPHQL"
status=$(curl -sk -X POST \
  --resolve "${DVGA_HOST}:443:${LAB_HOST_IP}" \
  "https://${DVGA_HOST}/graphql" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ pastes { id title } }"}' \
  -w '%{http_code}' -o /dev/null 2>/dev/null || echo "ERR")
[[ "$status" == "200" ]] && ok "GraphQL query  →  HTTP $status" || fail "GraphQL  →  HTTP $status"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "QUICK START COMMANDS (run from any host):"
echo ""
echo "# Register crAPI user:"
info "curl -sk -X POST --resolve '${CRAPI_HOST}:443:${LAB_HOST_IP}' \\"
info "  https://${CRAPI_HOST}/identity/api/auth/signup \\"
info "  -H 'Content-Type: application/json' \\"
info "  -d '{\"email\":\"test@${LAB_DOMAIN}\",\"password\":\"Password1!\",\"name\":\"Test\",\"number\":\"+15005550006\"}'"
echo ""
echo "# Login:"
info "TOKEN=\$(curl -sk -X POST --resolve '${CRAPI_HOST}:443:${LAB_HOST_IP}' \\"
info "  https://${CRAPI_HOST}/identity/api/auth/login \\"
info "  -H 'Content-Type: application/json' \\"
info "  -d '{\"email\":\"test@${LAB_DOMAIN}\",\"password\":\"Password1!\"}' \\"
info "  | python3 -c \"import sys,json; print(json.load(sys.stdin)['token'])\")"
echo ""
echo "# Dashboard:"
info "curl -sk --resolve '${CRAPI_HOST}:443:${LAB_HOST_IP}' \\"
info "  -H \"Authorization: Bearer \$TOKEN\" \\"
info "  https://${CRAPI_HOST}/identity/api/v2/user/dashboard | python3 -m json.tool"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
