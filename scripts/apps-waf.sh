#!/usr/bin/env bash
# scripts/apps-waf.sh on|off
# Applies the waf-enabled or waf-disabled overlay for each app in $LAB_APPS.
# Reads LAB_APPS from lab.env. Valid apps: crapi juiceshop dvga vampi
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  on)  OVERLAY="waf-enabled"  ;;
  off) OVERLAY="waf-disabled" ;;
  *)   echo "Usage: $0 on|off"; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${REPO_DIR}/lab.env"

# Minimal env loader (mirrors create-cluster.sh, no secrets needed here)
if [ -f "${ENV_FILE}" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ "${value}" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
    [[ "${value}" =~ ^\"(.*)\"$ ]] && value="${BASH_REMATCH[1]}"
    export "${key}=${value}" 2>/dev/null || true
  done < "${ENV_FILE}"
fi

APPS="${LAB_APPS:-crapi juiceshop dvga vampi}"
VALID="crapi juiceshop dvga vampi"

echo "Applying ${OVERLAY} to: ${APPS}"
echo ""

for app in ${APPS//,/ }; do
  if ! [[ " ${VALID} " == *" ${app} "* ]]; then
    echo "  WARN: unknown app '${app}' -- skipping (valid: ${VALID})"
    continue
  fi
  OVERLAY_PATH="${REPO_DIR}/overlays/${app}/${OVERLAY}"
  if [ ! -d "${OVERLAY_PATH}" ]; then
    echo "  WARN: ${OVERLAY_PATH} not found -- skipping"
    continue
  fi
  echo "==> ${app}: applying ${OVERLAY}"
  kubectl apply -k "${OVERLAY_PATH}"
  echo ""
done

echo "WAF ${MODE} complete -- apps: ${APPS}"