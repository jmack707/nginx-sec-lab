#!/usr/bin/env bash
# scripts/bigip-configure.sh
# Interactive prompt to configure BIG-IP connection details.
# Patches values/cis-nodeport.yaml and values/cis-cluster.yaml with the
# management IP, then creates the f5-bigip-ctlr-login secret in kube-system.
#
# Called by: task bigip:configure
# Run before: task bigip:cis:install
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  BIG-IP CIS Configuration${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "This configures BIG-IP CIS connection details and creates"
echo "the credential secret in the cluster."
echo ""
echo -e "${YELLOW}Ensure the cluster is running (task cluster) before proceeding.${NC}"
echo ""

# ── Collect inputs ───────────────────────────────────────────────────────────

read -rp "BIG-IP management IP or hostname: " BIGIP_MGMT_IP
if [[ -z "$BIGIP_MGMT_IP" ]]; then
  echo -e "${RED}ERROR: BIG-IP management IP is required${NC}"
  exit 1
fi

read -rp "BIG-IP admin username [admin]: " BIGIP_USER
BIGIP_USER="${BIGIP_USER:-admin}"

read -rsp "BIG-IP admin password: " BIGIP_PASS
echo ""
if [[ -z "$BIGIP_PASS" ]]; then
  echo -e "${RED}ERROR: BIG-IP password is required${NC}"
  exit 1
fi

read -rp "BIG-IP partition for CIS [kubernetes]: " BIGIP_PARTITION
BIGIP_PARTITION="${BIGIP_PARTITION:-kubernetes}"

echo ""
echo -e "${CYAN}Reachability check...${NC}"
if curl -sk -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 \
    -u "${BIGIP_USER}:${BIGIP_PASS}" \
    "https://${BIGIP_MGMT_IP}/mgmt/tm/sys/version" | grep -q "200"; then
  echo -e "${GREEN}✓ BIG-IP reachable and credentials valid${NC}"
else
  echo -e "${YELLOW}! Could not reach BIG-IP at ${BIGIP_MGMT_IP}${NC}"
  echo -e "${YELLOW}  Continuing anyway — verify connectivity manually${NC}"
fi

# ── Patch CIS values files ───────────────────────────────────────────────────

echo ""
echo -e "${CYAN}Patching CIS values files...${NC}"

for f in values/cis-nodeport.yaml values/cis-cluster.yaml; do
  sed -i "s|https://BIGIP_MGMT_IP_PLACEHOLDER|https://${BIGIP_MGMT_IP}|g" "$f"
  sed -i "s|BIGIP_PARTITION_PLACEHOLDER|${BIGIP_PARTITION}|g" "$f"
  echo -e "  ${GREEN}✓${NC} $f patched"
done

# ── Create credential secret ─────────────────────────────────────────────────

echo ""
echo -e "${CYAN}Creating f5-bigip-ctlr-login secret in kube-system...${NC}"

kubectl create secret generic f5-bigip-ctlr-login \
  --namespace kube-system \
  --from-literal=username="${BIGIP_USER}" \
  --from-literal=password="${BIGIP_PASS}" \
  --from-literal=url="https://${BIGIP_MGMT_IP}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "  ${GREEN}✓${NC} Secret created"

# ── Create BIG-IP partition ───────────────────────────────────────────────────

echo ""
echo -e "${CYAN}Creating BIG-IP partition '${BIGIP_PARTITION}' via iControl REST...${NC}"

HTTP_CODE=$(curl -sk -o /tmp/partition-resp.txt -w "%{http_code}" \
  -u "${BIGIP_USER}:${BIGIP_PASS}" \
  -X POST "https://${BIGIP_MGMT_IP}/mgmt/tm/auth/partition" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${BIGIP_PARTITION}\"}" 2>/dev/null || echo "ERR")

case "$HTTP_CODE" in
  200|201)
    echo -e "  ${GREEN}✓${NC} Partition '${BIGIP_PARTITION}' created"
    ;;
  409)
    echo -e "  ${YELLOW}~${NC} Partition '${BIGIP_PARTITION}' already exists (OK)"
    ;;
  ERR|*)
    echo -e "  ${YELLOW}!${NC} Could not create partition via REST (HTTP $HTTP_CODE)"
    echo "    Create manually: tmsh create auth partition ${BIGIP_PARTITION}"
    ;;
esac

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}BIG-IP configuration complete${NC}"
echo ""
echo "  Management IP : ${BIGIP_MGMT_IP}"
echo "  Partition     : ${BIGIP_PARTITION}"
echo "  Secret        : kube-system/f5-bigip-ctlr-login"
echo ""
echo -e "Next steps:"
echo -e "  NodePort mode : ${CYAN}task bigip:cis:install CIS_MODE=nodeport${NC}"
echo -e "  ClusterIP mode: ${CYAN}task bigip:tunnel:setup${NC} → then ${CYAN}task bigip:cis:install CIS_MODE=cluster${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
