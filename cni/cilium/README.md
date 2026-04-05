# cni/cilium/README.md
# Cilium CNI — Setup Guide

## Overview

This directory contains Helm values for deploying Cilium as the CNI on the
nginx-sec-lab k3d cluster. Two modes are supported:

| Mode | Values file | BIG-IP CIS pool-member-type |
|------|------------|----------------------------|
| Base (no BIG-IP) | `values-base.yaml` | nodeport |
| BIG-IP VTEP | `values-base.yaml` + `values-bigip.yaml` | cluster |

---

## Mode 1: Base (no BIG-IP VTEP)

```bash
task cluster CNI=cilium
task cni:install CNI=cilium
```

Cilium replaces kindnet. NGINX Ingress and demo apps work normally.
CIS uses NodePort mode — BIG-IP pool members are node IPs.

---

## Mode 2: BIG-IP VTEP (ClusterIP CIS mode)

### Prerequisites

1. BIG-IP VE running and reachable from Ubuntu host
2. BIG-IP SDN license active
3. BIG-IP internal self-IP has L2/L3 path to k3d bridge network

### Step-by-step

```bash
# 1. Generate and run BIG-IP TMSH commands
task bigip:tunnel:setup \
  BIGIP_INTERNAL_IP=192.168.200.60 \
  BIGIP_VTEP_SUBNET=10.1.6.0/24 \
  BIGIP_VTEP_SELFIP=10.1.6.1 \
  POD_CIDR=10.244.0.0/16

# 2. Get tunnel MAC from BIG-IP output of step 4
#    e.g. 00:50:56:A0:7D:D8

# 3. Spin up cluster with Cilium + VTEP
task cluster CNI=cilium
task cni:install CNI=cilium MODE=bigip \
  BIGIP_VTEP_IP=10.1.6.1 \
  BIGIP_VTEP_CIDR=10.1.6.0/24 \
  BIGIP_VTEP_MAC=00:50:56:A0:7D:D8

# 4. Install CIS in ClusterIP mode
task bigip:cis:install MODE=cluster
```

---

## Verification

```bash
# Cilium status
kubectl exec -n kube-system ds/cilium -- cilium status

# VTEP entries (after BIG-IP is configured)
kubectl exec -n kube-system ds/cilium -- cilium bpf vtep list

# Hubble UI (traffic visibility)
task cni:hubble
```

---

## Subnetting Rules

| Network | CIDR | Notes |
|---------|------|-------|
| Pod network | 10.244.0.0/16 | Managed by Cilium |
| Control-plane node pods | 10.244.0.0/24 | Auto-assigned by k3d |
| Worker 1 pods | 10.244.1.0/24 | Auto-assigned by k3d |
| Worker 2 pods | 10.244.2.0/24 | Auto-assigned by k3d |
| BIG-IP VTEP subnet | 10.1.6.0/24 | Must NOT overlap above |
| k3d node bridge | 172.18.0.0/16 | Docker bridge — BIG-IP must route here |

**Critical:** The BIG-IP VTEP self-IP subnet (10.1.6.0/24) must be outside
the pod CIDR (10.244.0.0/16). Using an overlapping subnet causes silent
ARP resolution failures.
