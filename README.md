# nginx-sec-lab

A fully repeatable Kubernetes lab environment for testing NGINX Ingress
application security using intentionally vulnerable demo applications.

## Requirements

- **OS**: Ubuntu 22.04 LTS or 24.04 LTS (amd64 or arm64)
- **RAM**: 8 GB minimum, 16 GB recommended
- **CPU**: 4 cores minimum, 8+ recommended
- **Disk**: 40 GB free (SSD recommended)
- **Internet**: Required on first run to pull ~8 GB of container images

## Stack

| Layer | Tool |
|---|---|
| Cluster | kind (Kubernetes in Docker) |
| CNI | kindnet (default) · Cilium · Flannel (planned) |
| Package management | Helmfile |
| Ingress | F5 NGINX Ingress Controller |
| WAF | NGINX App Protect v4 |
| TLS | cert-manager + step-cli local CA |
| App overlays | Kustomize |
| Automation | Taskfile |
| Observability | Prometheus + Grafana |
| Demo apps | crAPI · Juice Shop · DVGA · vAPI |

---

## Quickstart

### 1 — Install prerequisites (one-time)

```bash
# Clone the repo
git clone https://github.com/<your-org>/nginx-sec-lab.git
cd nginx-sec-lab

# Install all tools (Docker, kubectl, kind, helm, helmfile, task, step-cli)
sudo bash scripts/install-ubuntu.sh

# Log out and back in so the docker group takes effect, then verify
task check
```

### 2 — Create local CA (one-time)

```bash
task ca:init
```

### 3 — Spin up the lab

```bash
# Default: kindnet CNI, no BIG-IP
task up

# With Cilium CNI (required for BIG-IP ClusterIP mode)
task up CNI=cilium
```

### 4 — Run lab scenarios

```bash
task health                  # verify everything is up

task waf-off && task scan    # baseline — attacks succeed
task waf-on  && task scan    # protected — attacks blocked
task logs:waf                # watch App Protect security events

task locust                  # generate realistic crAPI traffic
task metrics                 # open Grafana at localhost:3000
task crapi:mail              # intercept password reset tokens
```

### 5 — Tear down

```bash
task down      # delete cluster (images cached for fast restart)
task reset     # full destroy + rebuild
```

---

## CNI Options

| Command | CNI | BIG-IP CIS mode |
|---|---|---|
| `task up` | kindnet (default) | NodePort |
| `task up CNI=cilium` | Cilium | NodePort |
| `task up CNI=cilium MODE=bigip ...` | Cilium + VTEP | ClusterIP |

See `cni/cilium/README.md` for the full BIG-IP ClusterIP setup procedure.

---

## BIG-IP CIS Integration

```bash
# 1. Configure BIG-IP connection (interactive)
task bigip:configure

# 2. Print TMSH tunnel commands (for ClusterIP mode)
task bigip:tunnel:setup \
  BIGIP_INTERNAL_IP=192.168.200.60 \
  BIGIP_VTEP_SUBNET=10.1.6.0/24 \
  BIGIP_VTEP_SELFIP=10.1.6.1

# 3. Install CIS
task bigip:cis:install CIS_MODE=nodeport   # or cluster
```

---

## Repo Layout

```
nginx-sec-lab/
├── Taskfile.yaml                    # Single entry point — run 'task --list'
├── kind-config.yaml                 # Cluster — kindnet CNI (default)
├── kind-config-no-cni.yaml          # Cluster — CNI disabled (Cilium/Flannel)
├── helmfile.yaml                    # Helm releases: cert-manager, NGINX, Prometheus
├── values/
│   ├── nginx-ingress.yaml           # NGINX Ingress Helm values (App Protect enabled)
│   ├── prometheus.yaml              # Prometheus + Grafana values
│   ├── cis-nodeport.yaml            # BIG-IP CIS NodePort mode
│   └── cis-cluster.yaml            # BIG-IP CIS ClusterIP mode
├── manifests/
│   ├── namespaces.yaml
│   └── cluster-issuer.yaml
├── cni/
│   ├── cilium/                      # Cilium values (base + BIG-IP VTEP)
│   └── flannel/                     # Flannel (planned)
├── base/                            # Kustomize base manifests
│   ├── crapi/                       # 7 services: identity, community, workshop,
│   │                                #   web, mailhog, mongodb, postgres
│   ├── juiceshop/
│   ├── dvga/
│   └── vapi/
├── overlays/
│   ├── crapi/{waf-enabled,waf-disabled}/
│   ├── juiceshop/{waf-enabled,waf-disabled}/
│   ├── dvga/{waf-enabled,waf-disabled}/
│   └── vapi/{waf-enabled,waf-disabled}/
├── policies/
│   ├── ap-policy-owasp.yaml         # OWASP CRS blocking policy
│   ├── ap-policy-dataguard.yaml     # PII scrubbing policy
│   └── ap-logconf.yaml
├── jobs/
│   ├── crapi-seed-job.yaml          # Register test users before Locust
│   ├── gotestwaf-job.yaml           # WAF bypass scanner
│   ├── nuclei-job.yaml              # Template-based vuln scanner
│   ├── locust-job.yaml              # Realistic API traffic generation
│   └── results-pvc.yaml
├── grafana/
│   └── nginx-dashboard.yaml         # Pre-built NGINX security dashboard
└── scripts/
    ├── install-ubuntu.sh            # One-shot prereq installer (Ubuntu 22.04/24.04)
    ├── check-prereqs.sh             # Verify tools and host readiness
    ├── health-check.sh              # Post-deploy verification
    ├── resolve-ingress-ip.sh        # Runtime ClusterIP injection for scan jobs
    ├── bigip-configure.sh           # Interactive BIG-IP setup
    └── bigip-cilium-tunnel.sh       # Print TMSH tunnel commands
```

---

## Task Reference

```bash
task --list          # show all available tasks with descriptions

# Core
task up              # full lab up (CNI=kindnet by default)
task down            # destroy cluster
task reset           # destroy + rebuild

# CNI
task cni:status      # show CNI and node assignments
task cni:hubble      # Cilium traffic visibility UI (CNI=cilium only)

# WAF scenarios
task waf-on          # enable App Protect on all apps
task waf-off         # disable App Protect (baseline)

# Scanning
task scan            # GoTestWAF against crAPI
task scan:nuclei     # Nuclei template scan all apps
task locust          # seed users + generate crAPI traffic

# Observability
task metrics         # Grafana at localhost:3000
task prometheus      # Prometheus at localhost:9090
task logs:waf        # tail App Protect security events
task logs:nginx      # tail NGINX access log

# App utilities
task crapi:seed      # register test users in crAPI
task crapi:mail      # MailHog UI at localhost:8025
task health          # run all post-deploy checks
task check           # verify prerequisites
```

---

## Module Mapping (learning-f5-adsp)

| Module | Relevance |
|---|---|
| Module 3 — BIG-IP LTM | Pool members, persistence, iRules against crAPI traffic |
| Module 5 — NGINX | Ingress Controller config, VirtualServer CRDs, App Protect policies |
| Module 6 — Web Security / AWAF | WAF policy tuning, OWASP CRS vs crAPI/DVGA/Juice Shop |
| Module 7 — API Security | BOLA, auth bypass, injection — full crAPI challenge set |
