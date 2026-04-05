# nginx-sec-lab

A fully repeatable Kubernetes security lab using k3d (k3s in Docker),
NGINX Ingress Controller, and intentionally vulnerable demo applications.

## Requirements

- **OS**: Ubuntu 22.04 LTS or 24.04 LTS (amd64 or arm64)
- **RAM**: 8 GB minimum, 16 GB recommended
- **CPU**: 4 cores minimum, 8+ recommended
- **Disk**: 40 GB free (SSD recommended)
- **Internet**: Required on first run (~8 GB of container images)

## Stack

| Layer | Tool |
|---|---|
| Cluster | k3d (k3s in Docker) |
| CNI | k3s flannel (default) · Cilium |
| Ingress | F5 NGINX Ingress Controller (OSS) |
| WAF | NGINX App Protect v4 (requires NGINX Plus) |
| TLS | cert-manager + openssl local CA |
| App overlays | Kustomize |
| Package management | Helmfile |
| Automation | Taskfile |
| Observability | Prometheus + Grafana |
| Demo apps | crAPI · Juice Shop · DVGA · vAPI |

---

## Quickstart

```bash
# 1. Install all tools (one-time)
sudo bash scripts/install-ubuntu.sh
newgrp docker    # pick up docker group without logging out

# 2. Verify
task check

# 3. Spin up the lab (CA created automatically on first run)
task up

# 4. Verify everything is healthy
task health
```

## Lab Scenarios

```bash
task waf-off && task scan    # baseline -- attacks succeed
task waf-on  && task scan    # protected -- compare results
task logs:waf                # watch App Protect security events

task locust                  # realistic crAPI traffic generation
task metrics                 # Grafana at http://localhost:3000
task crapi:mail              # intercept password reset tokens
```

## Tear Down

```bash
task down     # delete cluster (images cached for fast restart)
task reset    # full destroy + rebuild
```

---

## CNI Options

| Command | CNI | Notes |
|---|---|---|
| `task up` | k3s flannel (default) | Simplest, no extra config |
| `CNI=cilium task up` | Cilium | Required for BIG-IP ClusterIP mode |

See `cni/cilium/README.md` for the full BIG-IP ClusterIP setup.

---

## BIG-IP CIS Integration

```bash
task bigip:configure              # interactive: set mgmt IP + credentials
task bigip:cis:install            # NodePort mode (default)
CIS_MODE=cluster task bigip:cis:install  # ClusterIP mode (requires Cilium)
```

---

## Repo Layout

```
nginx-sec-lab/
├── Taskfile.yaml                  # Single entry point
├── helmfile.yaml                  # Helm releases
├── values/
│   ├── nginx-ingress.yaml         # NGINX Ingress Helm values
│   ├── prometheus.yaml            # Prometheus + Grafana values
│   ├── cis-nodeport.yaml          # BIG-IP CIS NodePort mode
│   └── cis-cluster.yaml          # BIG-IP CIS ClusterIP mode
├── manifests/
│   ├── namespaces.yaml
│   └── cluster-issuer.yaml
├── cni/
│   ├── cilium/                    # Cilium values + README
│   └── flannel/                   # Flannel (planned)
├── base/                          # Kustomize base manifests
│   ├── crapi/                     # 7 services
│   ├── juiceshop/
│   ├── dvga/
│   └── vapi/
├── overlays/
│   ├── crapi/{waf-enabled,waf-disabled}/
│   ├── juiceshop/{waf-enabled,waf-disabled}/
│   ├── dvga/{waf-enabled,waf-disabled}/
│   └── vapi/{waf-enabled,waf-disabled}/
├── policies/                      # NGINX App Protect WAF policies
├── jobs/                          # Scanner + traffic generation jobs
├── grafana/                       # Pre-built dashboard ConfigMap
└── scripts/
    ├── install-ubuntu.sh          # One-shot prereq installer
    ├── check-prereqs.sh           # Verify tools + host readiness
    ├── create-cluster.sh          # k3d cluster creation
    ├── install-cni.sh             # CNI dispatcher
    ├── install-cilium.sh          # Cilium install for k3d
    ├── health-check.sh            # Post-deploy verification
    ├── pre-deploy.sh              # Resources needed before helmfile
    ├── resolve-ingress-ip.sh      # Runtime ClusterIP for scan jobs
    ├── run-scan.sh                # GoTestWAF / Nuclei wrapper
    ├── run-locust.sh              # User seed + Locust start
    ├── bigip-configure.sh         # Interactive BIG-IP setup
    └── bigip-cilium-tunnel.sh     # Print TMSH tunnel commands
```

---

## Task Reference

```bash
task --list          # all tasks with descriptions

task up              # full lab up
task down            # destroy cluster
task reset           # destroy + rebuild
task check           # verify prerequisites
task health          # post-deploy verification

task waf-on          # enable App Protect WAF
task waf-off         # disable WAF (baseline)
task scan            # GoTestWAF against crAPI
task scan:nuclei     # Nuclei scan all apps
task locust          # seed users + traffic generation

task metrics         # Grafana at http://localhost:3000
task prometheus      # Prometheus at http://localhost:9090
task logs:waf        # tail App Protect events
task logs:nginx      # tail NGINX access log

task crapi:seed      # register test users
task crapi:mail      # MailHog at http://localhost:8025
```

---

## Module Mapping (learning-f5-adsp)

| Module | Relevance |
|---|---|
| Module 3 -- BIG-IP LTM | Pool members, persistence, iRules against crAPI |
| Module 5 -- NGINX | Ingress config, VirtualServer CRDs, App Protect |
| Module 6 -- Web Security / AWAF | WAF policy tuning vs crAPI/DVGA/Juice Shop |
| Module 7 -- API Security | BOLA, auth bypass, injection -- full crAPI challenge set |
