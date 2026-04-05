#!/usr/bin/env bash
# scripts/health-check.sh
# Verifies all lab components are healthy after 'task up'.
# Reads hostnames from lab.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lab.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC}  $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; WARN=$((WARN+1)); }
info() { echo -e "     ${CYAN}$*${NC}"; }

section() {
  echo ""
  echo -e "${BOLD}$*${NC}"
  echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}"
}

# ── Nodes ──────────────────────────────────────────────────────────────────
section "CLUSTER NODES"
not_ready=$(kubectl get nodes --no-headers 2>/dev/null \
  | awk '$2 != "Ready" {print $1}')
if [[ -z "$not_ready" ]]; then
  node_count=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
  ok "All $node_count nodes Ready"
  kubectl get nodes --no-headers | while read -r name status _ _ _; do
    info "$name  →  $status"
  done
else
  fail "Nodes not Ready: $not_ready"
fi

# ── Namespaces ─────────────────────────────────────────────────────────────
section "NAMESPACES"
for ns in nginx-ingress cert-manager monitoring crapi juice-shop dvga vapi; do
  if kubectl get namespace "$ns" &>/dev/null; then
    ok "namespace/$ns exists"
  else
    fail "namespace/$ns MISSING"
  fi
done

# ── Infrastructure pods ────────────────────────────────────────────────────
section "INFRASTRUCTURE PODS"

check_deploy() {
  local ns="$1"; local name="$2"
  local ready desired
  ready=$(kubectl get deployment "$name" -n "$ns" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  desired=$(kubectl get deployment "$name" -n "$ns" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  if [[ "$ready" == "$desired" && "$ready" != "0" ]]; then
    ok "$ns/$name  ($ready/$desired ready)"
  else
    fail "$ns/$name  ($ready/$desired ready)"
  fi
}

check_deploy nginx-ingress nginx-ingress-controller
check_deploy cert-manager  cert-manager
check_deploy cert-manager  cert-manager-webhook
check_deploy monitoring    kube-prometheus-stack-grafana

# ── TLS Certificates ───────────────────────────────────────────────────────
section "TLS CERTIFICATES"

# Derive cert names from hostnames
CRAPI_NS="crapi"; CRAPI_CERT="crapi-tls"
JS_NS="juice-shop"; JS_CERT="juiceshop-tls"
DVGA_NS="dvga"; DVGA_CERT="dvga-tls"
VAPI_NS="vapi"; VAPI_CERT="vapi-tls"

for ns_cert in "${CRAPI_NS}:${CRAPI_CERT}" "${JS_NS}:${JS_CERT}" "${DVGA_NS}:${DVGA_CERT}" "${VAPI_NS}:${VAPI_CERT}"; do
  ns="${ns_cert%%:*}"; cert="${ns_cert##*:}"
  ready=$(kubectl get certificate "$cert" -n "$ns" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$ready" == "True" ]]; then
    ok "$ns/$cert  Ready"
  else
    warn "$ns/$cert  NOT ready yet"
  fi
done

# ── ClusterIssuer ──────────────────────────────────────────────────────────
section "CERT-MANAGER ISSUER"
issuer_ready=$(kubectl get clusterissuer local-ca-issuer \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$issuer_ready" == "True" ]]; then
  ok "ClusterIssuer/local-ca-issuer  Ready"
else
  fail "ClusterIssuer/local-ca-issuer  NOT ready"
fi

# ── App Protect policies ───────────────────────────────────────────────────
section "APP PROTECT POLICIES"
for pol in owasp-crs dataguard-alarm; do
  if kubectl get apppolicy "$pol" -n nginx-ingress &>/dev/null; then
    ok "APPolicy/$pol  present"
  else
    warn "APPolicy/$pol  not found  (NGINX Plus required for enforcement)"
  fi
done

# ── Demo app pods ──────────────────────────────────────────────────────────
section "DEMO APPLICATION PODS"

check_app_pods() {
  local ns="$1"
  local not_running total
  not_running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" {print $1"("$3")"}' | tr '\n' ' ')
  total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ -z "$not_running" && "$total" -gt 0 ]]; then
    ok "$ns  ($total pods Running)"
  elif [[ "$total" -eq 0 ]]; then
    warn "$ns  no pods found  (run: task apps:up)"
  else
    fail "$ns  pods not ready: $not_running"
  fi
}

check_app_pods crapi
check_app_pods juice-shop
check_app_pods dvga
check_app_pods vapi

# ── Ingress HTTP endpoints ─────────────────────────────────────────────────
section "INGRESS HTTP ENDPOINTS (via ${LAB_HOST_IP}:443)"

check_endpoint() {
  local host="$1"
  local path="${2:-/}"
  local expected="${3:-200}"
  local status
  status=$(curl -sk -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    --resolve "${host}:443:${LAB_HOST_IP}" \
    "https://${host}${path}" 2>/dev/null || echo "ERR")
  if [[ "$status" == "$expected" ]]; then
    ok "${host}${path}  →  HTTP $status"
  elif [[ "$status" == "ERR" ]]; then
    fail "${host}${path}  →  connection failed"
  else
    warn "${host}${path}  →  HTTP $status  (expected $expected)"
  fi
}

check_endpoint "${CRAPI_HOST}"     "/"  "200"
check_endpoint "${JUICESHOP_HOST}" "/"  "200"
check_endpoint "${DVGA_HOST}"      "/"  "200"
check_endpoint "${VAPI_HOST}"      "/"  "200"

# ── WAF status ─────────────────────────────────────────────────────────────
section "WAF STATUS"
for ns_ing in "crapi:crapi" "juice-shop:juice-shop" "dvga:dvga" "vapi:vapi"; do
  ns="${ns_ing%%:*}"; ing="${ns_ing##*:}"
  waf=$(kubectl get ingress "$ing" -n "$ns" \
    -o jsonpath='{.metadata.annotations.nginx\.org/app-protect-enable}' 2>/dev/null || echo "")
  if [[ "$waf" == "True" ]]; then
    ok "$ns/$ing  WAF ENABLED"
  else
    warn "$ns/$ing  WAF DISABLED  (baseline -- run: task waf-on)"
  fi
done

# ── /etc/hosts hint ────────────────────────────────────────────────────────
section "CLIENT ACCESS"
echo -e "  Add to client /etc/hosts:"
echo -e "  ${CYAN}${LAB_HOST_IP}  ${CRAPI_HOST} ${JUICESHOP_HOST} ${DVGA_HOST} ${VAPI_HOST}${NC}"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}$(printf '━%.0s' {1..50})${NC}"
if (( FAIL == 0 && WARN == 0 )); then
  echo -e "  ${GREEN}${BOLD}ALL CHECKS PASSED${NC}  ($PASS passed)"
elif (( FAIL == 0 )); then
  echo -e "  ${YELLOW}${BOLD}PASSED WITH WARNINGS${NC}  ($PASS passed, $WARN warnings)"
  echo -e "  Lab is functional."
else
  echo -e "  ${RED}${BOLD}$FAIL CHECK(S) FAILED${NC}  ($PASS passed, $WARN warnings, $FAIL failed)"
fi
echo -e "${CYAN}$(printf '━%.0s' {1..50})${NC}"
echo ""

(( FAIL == 0 ))
