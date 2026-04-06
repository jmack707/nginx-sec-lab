# nginx-sec-lab

A fully repeatable Kubernetes security lab using k3d (k3s in Docker),
NGINX Ingress Controller, and intentionally vulnerable demo applications.

## Requirements

- **OS**: Ubuntu 22.04 LTS or 24.04 LTS (amd64 or arm64)
- **RAM**: 8 GB minimum, 16 GB recommended
- **CPU**: 4 cores minimum
- **Disk**: 40 GB minimum, 60 GB recommended
  - If pods evict with `disk-pressure` taint: resize VM disk in Proxmox, then `sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2`
- **Network**: External clients must be able to reach the lab host IP on ports 80/443

## Stack

| Layer | Tool |
|---|---|
| Cluster | k3d (k3s in Docker) |
| CNI | k3s flannel (default) · Cilium |
| Ingress | F5 NGINX Ingress Controller (OSS or Plus) |
| WAF | NGINX App Protect v4 (NGINX Plus only) |
| TLS | cert-manager + openssl local CA |
| App overlays | Kustomize |
| Package management | Helmfile |
| Automation | Taskfile |
| Observability | Prometheus + Grafana |
| Demo apps | crAPI · Juice Shop · DVGA · VAmPI |

---

## Setup (one-time per VM)

### 1 — Install prerequisites

```bash
sudo bash scripts/install-ubuntu.sh
newgrp docker
task check
```

### 2 — Configure the lab

Edit `lab.env` before doing anything else:

```bash
nano lab.env
```

Key settings:
```bash
LAB_HOST_IP=172.16.1.136     # IP of this Ubuntu machine
LAB_DOMAIN=lab.local          # domain for all app hostnames
DOCKERHUB_USER=yourusername   # Docker Hub account (avoids rate limits)
NGINX_JWT=                    # NGINX Plus JWT (leave blank for OSS)
NGINX_MODE=oss                # oss or plus
```

### 3 — Set up local image registry

```bash
task registry:setup    # creates local k3d registry (survives task reset)
task registry:cache    # pulls all images and stores them locally
```

`registry:cache` reads credentials from `lab.env` and logs in automatically.
After this, `task reset` runs fully offline.

---

## Quickstart

```bash
task up        # full lab up (reads lab.env for IP and domain)
task health    # verify everything is running
task test      # curl smoke tests against all endpoints
```

---

## Lab URLs

After `task up`, add to client `/etc/hosts`:

```
<LAB_HOST_IP>  crapi.<LAB_DOMAIN> juiceshop.<LAB_DOMAIN> dvga.<LAB_DOMAIN> vampi.<LAB_DOMAIN>
```

| App | URL | Notes |
|---|---|---|
| crAPI | `https://crapi.<LAB_DOMAIN>` | API security challenges |
| Juice Shop | `https://juiceshop.<LAB_DOMAIN>` | Web app vulnerabilities |
| DVGA | `https://dvga.<LAB_DOMAIN>` | GraphQL vulnerabilities |
| VAmPI | `https://vampi.<LAB_DOMAIN>` | OWASP API Top 10 (SQLi, BOLA, mass assignment, JWT bypass) |
| Grafana | `http://<LAB_HOST_IP>:3000` | Metrics (run: `task metrics`) |
| MailHog | `http://<LAB_HOST_IP>:8025` | crAPI email capture (run: `task crapi:mail`) |

TLS certificates are signed by the local CA (`root_ca.crt` in repo root).
Install on Windows: `certutil -addstore -f "ROOT" root_ca.crt`
Install on Mac: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root_ca.crt`

---

## Lab Scenarios

```bash
task waf-off && task scan    # baseline -- attacks succeed
task waf-on  && task scan    # protected -- attacks blocked
task logs:waf                # watch App Protect security events
task locust                  # realistic crAPI traffic generation
task metrics                 # Grafana at http://<LAB_HOST_IP>:3000
task crapi:mail              # intercept crAPI password reset tokens
```

---

## Tear Down

```bash
task down     # delete cluster (registry and images preserved)
task reset    # full destroy + rebuild
```

---

## CNI Options

| Command | CNI | Notes |
|---|---|---|
| `task up` | k3s flannel (default) | Simplest setup |
| `CNI=cilium task up` | Cilium | Required for BIG-IP ClusterIP mode |

---

## BIG-IP CIS Integration

```bash
task bigip:configure              # interactive: set mgmt IP + credentials
task bigip:cis:install            # NodePort mode (default)
CIS_MODE=cluster task bigip:cis:install  # ClusterIP mode (requires Cilium)
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
task test            # curl smoke tests

task registry:setup  # create local image registry (one-time)
task registry:cache  # pull and cache all images
task registry:ls     # list cached images

task waf-on          # enable App Protect WAF
task waf-off         # disable WAF (baseline)
task scan            # GoTestWAF against crAPI
task scan:nuclei     # Nuclei scan all apps
task locust          # seed users + traffic generation

task metrics         # Grafana dashboard
task prometheus      # Prometheus UI
task logs:waf        # tail App Protect events
task logs:nginx      # tail NGINX access log

task crapi:seed      # register test users
task crapi:mail      # MailHog email capture
```

---

## Module Mapping (learning-f5-adsp)

| Module | Relevance |
|---|---|
| Module 3 -- BIG-IP LTM | Pool members, persistence, iRules against crAPI |
| Module 5 -- NGINX | Ingress config, VirtualServer CRDs, App Protect |
| Module 6 -- Web Security / AWAF | WAF policy tuning vs crAPI/DVGA/Juice Shop |
| Module 7 -- API Security | BOLA, auth bypass, injection -- full crAPI challenge set |
