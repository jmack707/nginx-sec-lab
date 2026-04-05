#!/usr/bin/env bash
# scripts/bigip-cilium-tunnel.sh
# ─────────────────────────────────────────────────────────────────────────────
# Generates TMSH commands to configure BIG-IP for Cilium VTEP / ClusterIP mode
# Run locally — outputs commands to copy-paste into BIG-IP TMSH or run via
# Ansible/Terraform against the BIG-IP iControl REST API.
#
# Usage:
#   task bigip:tunnel:setup \
#     BIGIP_INTERNAL_IP=192.168.200.60 \
#     BIGIP_VTEP_SUBNET=10.1.6.0/24 \
#     BIGIP_VTEP_SELFIP=10.1.6.1 \
#     POD_CIDR=10.244.0.0/16
#
# After running, update cni/cilium/values-bigip.yaml with:
#   - vtep.endpoint  = BIGIP_VTEP_SELFIP
#   - vtep.cidr      = BIGIP_VTEP_SUBNET
#   - vtep.mac       = (MAC shown in step 4 output)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BIGIP_INTERNAL_IP="${BIGIP_INTERNAL_IP:-192.168.200.60}"
BIGIP_VTEP_SUBNET="${BIGIP_VTEP_SUBNET:-10.1.6.0/24}"
BIGIP_VTEP_SELFIP="${BIGIP_VTEP_SELFIP:-10.1.6.1}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

cat <<EOF
═══════════════════════════════════════════════════════════════════════════════
BIG-IP TMSH — Cilium VTEP Setup for CIS ClusterIP Mode
═══════════════════════════════════════════════════════════════════════════════

Run the following commands on BIG-IP (TMSH or iControl REST).

IMPORTANT NOTES:
  • flooding-type must be 'multipoint' for Cilium (not 'none' like Flannel)
  • VNI key 68 — Cilium reserves keys 1-6 internally, never use them
  • Self-IP subnet must be /24, NOT overlapping any node's podCIDR
  • BIG-IP SDN license required for VXLAN tunnel creation
  • BIG-IP internal self-IP must have L3 reachability to kind node IPs

───────────────────────────────────────────────────────────────────────────────
STEP 1 — Create Kubernetes partition (if not exists)
───────────────────────────────────────────────────────────────────────────────
tmsh create auth partition kubernetes

───────────────────────────────────────────────────────────────────────────────
STEP 2 — Create VXLAN tunnel profile
  flooding-type multipoint = BIG-IP sends ARP broadcast to all Cilium nodes
───────────────────────────────────────────────────────────────────────────────
tmsh create net tunnels vxlan fl-vxlan \\
  port 8472 \\
  flooding-type multipoint

───────────────────────────────────────────────────────────────────────────────
STEP 3 — Create VXLAN tunnel
  key 68 = VNI (Cilium reserves 1-6)
  local-address = BIG-IP interface IP reachable by kind nodes
───────────────────────────────────────────────────────────────────────────────
tmsh create net tunnels tunnel flannel_vxlan \\
  key 68 \\
  profile fl-vxlan \\
  local-address ${BIGIP_INTERNAL_IP}

───────────────────────────────────────────────────────────────────────────────
STEP 4 — Get tunnel MAC address (needed for values-bigip.yaml vtep.mac)
───────────────────────────────────────────────────────────────────────────────
tmsh show net tunnels tunnel flannel_vxlan all-properties
# → Copy the 'MAC Address' value from the output
# → Add it to cni/cilium/values-bigip.yaml as vtep.mac

───────────────────────────────────────────────────────────────────────────────
STEP 5 — Create self-IP on the tunnel VLAN
  Address = BIGIP_VTEP_SELFIP from this subnet: ${BIGIP_VTEP_SUBNET}
  allow-service default = allows BIG-IP to originate VXLAN-encapped traffic
───────────────────────────────────────────────────────────────────────────────
tmsh create net self ${BIGIP_VTEP_SELFIP} \\
  address ${BIGIP_VTEP_SELFIP}/255.255.255.0 \\
  allow-service default \\
  vlan flannel_vxlan

───────────────────────────────────────────────────────────────────────────────
STEP 6 — Static route: pod CIDR → VXLAN tunnel interface
  BIG-IP uses this route to forward traffic toward pod IPs via the tunnel
───────────────────────────────────────────────────────────────────────────────
tmsh create net route ciliumPodRoute \\
  network ${POD_CIDR} \\
  interface flannel_vxlan

───────────────────────────────────────────────────────────────────────────────
STEP 7 — Save config
───────────────────────────────────────────────────────────────────────────────
tmsh save sys config

───────────────────────────────────────────────────────────────────────────────
STEP 8 — Verify tunnel is up after CIS deploys
───────────────────────────────────────────────────────────────────────────────
# Should show FDB entries for each Kubernetes node
tmsh show net fdb tunnel flannel_vxlan

# Should show ARP entries for pod IPs after traffic flows
tmsh show net arp

# Should show the static pod route
tmsh show net route ciliumPodRoute

───────────────────────────────────────────────────────────────────────────────
NEXT STEPS
───────────────────────────────────────────────────────────────────────────────
1. Copy MAC from Step 4 → cni/cilium/values-bigip.yaml vtep.mac
2. Run: task cni:install CNI=cilium MODE=bigip \\
         BIGIP_VTEP_IP=${BIGIP_VTEP_SELFIP} \\
         BIGIP_VTEP_CIDR=${BIGIP_VTEP_SUBNET} \\
         BIGIP_VTEP_MAC=<mac-from-step-4>
3. Run: task bigip:cis:install to deploy CIS with pool-member-type=cluster
═══════════════════════════════════════════════════════════════════════════════
EOF
