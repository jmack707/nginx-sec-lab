#!/usr/bin/env bash
# scripts/health-check.sh
# Verifies all lab components are healthy after 'task up'
# Called by: task health
set -euo pipefail

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
  local ready
  ready=$(kubectl get deployment "$name" -n "$ns" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  local desired
  desired=$(kubectl get deployment "$name" -n "$ns" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  if [[ "$ready" == "$desired" && "$ready" != "0" ]]; then
    ok "$ns/$name  ($ready/$desired ready)"
  else
    fail "$ns/$name  ($ready/$desired ready)"
  fi
}

check_deploy nginx-ingress nginx-ingress
check_deploy cert-manager  cert-manager
check_deploy cert-manager  cert-manager-webhook
check_deploy monitoring    kube-prometheus-stack-grafana

# ── TLS Certificates ───────────────────────────────────────────────────────
section "TLS CERTIFICATES"
for ns_cert in "crapi:crapi-tls" "juice-shop:juiceshop-tls" "dvga:dvga-tls" "vapi:vapi-tls"; do
  ns="${ns_cert%%:*}"
  cert="${ns_cert##*:}"
  ready=$(kubectl get certificate "$cert" -n "$ns" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$ready" == "True" ]]; then
    ok "$ns/$cert  Ready"
  else
    warn "$ns/$cert  NOT ready yet  (cert-manager may still be provisioning)"
  fi
done

# ── ClusterIssuer ──────────────────────────────────────────────────────────
section "CERT-MANAGER ISSUER"
issuer_ready=$(kubectl get clusterissuer local-ca-issuer \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$issuer_ready" == "True" ]]; then
  ok "ClusterIssuer/local-ca-issuer  Ready"
else
  fail "ClusterIssuer/local-ca-issuer  NOT ready — check CA secret"
fi

# ── App Protect policies ───────────────────────────────────────────────────
section "APP PROTECT POLICIES"
for pol in owasp-crs dataguard-alarm; do
  if kubectl get apppolicy "$pol" -n nginx-ingress &>/dev/null; then
    ok "APPolicy/$pol  present"
  else
    warn "APPolicy/$pol  not found  (App Protect may not be enabled)"
  fi
done

# ── Demo app pods ──────────────────────────────────────────────────────────
section "DEMO APPLICATION PODS"

check_app_pods() {
  local ns="$1"
  local not_running
  not_running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" {print $1"("$3")"}' | tr '\n' ' ')
  local total
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

# ── Ingress endpoints ──────────────────────────────────────────────────────
section "INGRESS HTTP ENDPOINTS (via localhost:8443)"

check_endpoint() {
  local host="$1"
  local path="${2:-/}"
  local expected="${3:-200}"

  local status
  status=$(curl -sk -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 \
    --max-time 10 \
    -H "Host: $host" \
    "https://localhost:8443${path}" 2>/dev/null || echo "ERR")

  if [[ "$status" == "$expected" ]]; then
    ok "$host$path  →  HTTP $status"
  elif [[ "$status" == "ERR" ]]; then
    fail "$host$path  →  connection failed  (is NGINX Ingress running?)"
  else
    warn "$host$path  →  HTTP $status  (expected $expected — app may still be starting)"
  fi
}

check_endpoint "crapi.lab.local"      "/"    "200"
check_endpoint "juiceshop.lab.local"  "/"    "200"
check_endpoint "dvga.lab.local"       "/"    "200"
check_endpoint "vapi.lab.local"       "/vapi" "200"

# ── WAF status ─────────────────────────────────────────────────────────────
section "WAF STATUS"
for app_ns_ing in "crapi:crapi:crapi" "juice-shop:juiceshop:juice-shop" "dvga:dvga:dvga" "vapi:vapi:vapi"; do
  ns="${app_ns_ing%%:*}"
  rest="${app_ns_ing#*:}"
  ing="${rest##*:}"
  waf=$(kubectl get ingress "$ing" -n "$ns" \
    -o jsonpath='{.metadata.annotations.nginx\.org/app-protect-enable}' 2>/dev/null || echo "")
  if [[ "$waf" == "True" ]]; then
    ok "$ns/$ing  WAF ENABLED"
  else
    warn "$ns/$ing  WAF DISABLED  (baseline mode — run: task waf-on)"
  fi
done

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}$(printf '━%.0s' {1..50})${NC}"
if (( FAIL == 0 && WARN == 0 )); then
  echo -e "  ${GREEN}${BOLD}ALL CHECKS PASSED${NC}  ($PASS passed)"
elif (( FAIL == 0 )); then
  echo -e "  ${YELLOW}${BOLD}PASSED WITH WARNINGS${NC}  ($PASS passed, $WARN warnings)"
  echo -e "  Lab is functional. Review warnings above."
else
  echo -e "  ${RED}${BOLD}$FAIL CHECK(S) FAILED${NC}  ($PASS passed, $WARN warnings, $FAIL failed)"
  echo -e "  Fix failures before running security scans."
fi
echo -e "${CYAN}$(printf '━%.0s' {1..50})${NC}"
echo ""

(( FAIL == 0 ))
