#!/usr/bin/env bash
# scripts/svc-mode.sh nodeport|clusterip
#
# Switches all demo app Services between NodePort and ClusterIP.
# Applies the matching Kustomize overlay for each app in LAB_APPS.
#
# Usage:
#   bash scripts/svc-mode.sh nodeport    # expose apps via NodePort
#   bash scripts/svc-mode.sh clusterip   # return to ClusterIP (NIC only)
#
# NodePort assignments (fixed, sourced from lab.env):
#   crapi      LAB_NODEPORT_CRAPI      default 30080
#   juiceshop  LAB_NODEPORT_JUICESHOP  default 30300
#   dvga       LAB_NODEPORT_DVGA       default 30501
#   vampi      LAB_NODEPORT_VAMPI      default 30082
#
# These ports must be in the range declared at cluster creation time
# (scripts/create-cluster.sh --port "30080-30600:30080-30600@loadbalancer").
# Changing the range requires 'task reset'.
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  nodeport|np)  OVERLAY="svc-nodeport"  ;;
  clusterip|ci) OVERLAY="svc-clusterip" ;;
  *)
    echo "Usage: $0 nodeport|clusterip"
    echo ""
    echo "  nodeport   -- expose apps on fixed NodePorts (bypass NIC)"
    echo "  clusterip  -- return to ClusterIP (NIC ingress path)"
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${REPO_DIR}/lab.env"

# ── Load lab.env ─────────────────────────────────────────────────────────────
if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: ${ENV_FILE} not found"; exit 1
fi
while IFS= read -r line || [ -n "$line" ]; do
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]]             && continue
  key="${line%%=*}"
  value="${line#*=}"
  value="${value%%#*}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [[ "${value}" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
  [[ "${value}" =~ ^\"(.*)\"$ ]] && value="${BASH_REMATCH[1]}"
  export "${key}=${value}" 2>/dev/null || true
done < "${ENV_FILE}"

# ── Defaults ──────────────────────────────────────────────────────────────────
APPS="${LAB_APPS:-crapi juiceshop dvga vampi}"
VALID="crapi juiceshop dvga vampi"

LAB_NODEPORT_CRAPI="${LAB_NODEPORT_CRAPI:-30080}"
LAB_NODEPORT_JUICESHOP="${LAB_NODEPORT_JUICESHOP:-30300}"
LAB_NODEPORT_DVGA="${LAB_NODEPORT_DVGA:-30501}"
LAB_NODEPORT_VAMPI="${LAB_NODEPORT_VAMPI:-30082}"

LAB_HOST_IP="${LAB_HOST_IP:-}"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; }
info() { echo -e "  ${CYAN}→${NC}  $*"; }

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  nginx-sec-lab — Service mode: ${MODE}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

ERRORS=0

for app in ${APPS//,/ }; do
  if ! [[ " ${VALID} " == *" ${app} "* ]]; then
    warn "Unknown app '${app}' — skipping (valid: ${VALID})"
    continue
  fi

  OVERLAY_PATH="${REPO_DIR}/overlays/${app}/${OVERLAY}"

  if [ ! -d "${OVERLAY_PATH}" ]; then
    fail "${app}: overlay not found at ${OVERLAY_PATH}"
    ERRORS=$((ERRORS+1))
    continue
  fi

  echo -e "==> ${CYAN}${app}${NC}: applying ${OVERLAY}"

  if ! kubectl apply -k "${OVERLAY_PATH}" 2>&1; then
    fail "${app}: kubectl apply failed"
    ERRORS=$((ERRORS+1))
    continue
  fi

  ok "${app}: ${OVERLAY} applied"
  echo ""
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ $ERRORS -gt 0 ]; then
  fail "Completed with ${ERRORS} error(s) — check output above"
  exit 1
fi

if [ "$MODE" = "nodeport" ] || [ "$MODE" = "np" ]; then
  echo -e "${GREEN}NodePort access map:${NC}"
  echo ""
  printf "  %-12s  %-10s  %s\n" "App" "NodePort" "URL"
  printf "  %-12s  %-10s  %s\n" "───────────" "─────────" "──────────────────────────────"

  for app in ${APPS//,/ }; do
    case "$app" in
      crapi)     PORT="${LAB_NODEPORT_CRAPI}"      ;;
      juiceshop) PORT="${LAB_NODEPORT_JUICESHOP}"  ;;
      dvga)      PORT="${LAB_NODEPORT_DVGA}"        ;;
      vampi)     PORT="${LAB_NODEPORT_VAMPI}"       ;;
      *) continue ;;
    esac
    if [ -n "${LAB_HOST_IP}" ]; then
      printf "  %-12s  %-10s  http://%s:%s\n" "$app" "$PORT" "${LAB_HOST_IP}" "$PORT"
    else
      printf "  %-12s  %-10s  http://<LAB_HOST_IP>:%s\n" "$app" "$PORT" "$PORT"
    fi
  done
  echo ""
  echo -e "  ${CYAN}NIC ingress (HTTPS) still active — both paths work simultaneously.${NC}"
else
  echo -e "${GREEN}ClusterIP mode restored — all apps reachable via NIC ingress only.${NC}"
fi

echo ""
echo "Done."
