#!/usr/bin/env bash
# scripts/generate-crapi-env.sh
# Patches crAPI web deployment with correct hostnames from lab.env.
# Called by pre-deploy.sh when LAB_DOMAIN is set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lab.env"

echo "Patching crAPI web deployment for domain: ${LAB_DOMAIN}..."

kubectl set env deployment/crapi-web -n crapi \
  REACT_APP_IDENTITY_SERVICE="https://${CRAPI_HOST}/identity" \
  REACT_APP_COMMUNITY_SERVICE="https://${CRAPI_HOST}/community" \
  REACT_APP_WORKSHOP_SERVICE="https://${CRAPI_HOST}/workshop" \
  2>/dev/null || echo "  (crapi-web not deployed yet -- will apply on next deploy)"
