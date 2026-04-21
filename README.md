# nginx-sec-lab

A fully repeatable Kubernetes security lab using k3d, F5 NGINX Ingress
Controller, and four intentionally vulnerable demo applications. Built
for F5 ADSP training and NGINX security experimentation.

**What you get after `task up`:**

- A three-node k3d cluster running crAPI, Juice Shop, DVGA, and VAmPI
  behind NGINX Ingress with TLS from a local CA.
- A Kustomize-driven WAF toggle (`task waf-on` / `task waf-off`) —
  shadow mode on OSS, enforcement on NGINX Plus.
- Prometheus + Grafana with two purpose-built dashboards (OSS metrics
  and Plus metrics), scraped via a static PodMonitor.
- Repeatable scan workflows (GoTestWAF, Nuclei) and realistic traffic
  generation (Locust).

Everything is driven from [`Taskfile.yaml`](./Taskfile.yaml) — no
kubectl-golf required.

---

## Documentation

| Goal | Go to |
|---|---|
| Get the lab running | [Quickstart](#quickstart) below |
| Work through a vulnerability scenario | [`docs/scenarios/`](./docs/scenarios/) — 5 hands-on walkthroughs |
| Understand how the lab is built | [`docs/architecture/`](./docs/architecture/) — observability, WAF toggle, image layers |
| Recover from a broken state | [`docs/runbooks/cold-start-recovery.md`](./docs/runbooks/cold-start-recovery.md) |
| Upgrade to NGINX Plus | [`docs/runbooks/plus-upgrade.md`](./docs/runbooks/plus-upgrade.md) |
| Install the lab CA on clients | [`docs/runbooks/certificate-trust.md`](./docs/runbooks/certificate-trust.md) |
| See why a design decision was made | [`docs/adr/`](./docs/adr/) — Architecture Decision Records |

### Scenarios at a glance

| # | Scenario | App | OWASP |
|---|---|---|---|
| [01](./docs/scenarios/01-crapi-bola.md) | BOLA — access another user's vehicle | crAPI | API1:2023 |
| [02](./docs/scenarios/02-vampi-sqli.md) | SQL injection in login | VAmPI | API8:2023 |
| [03](./docs/scenarios/03-vampi-jwt-weak.md) | JWT weak-key forgery | VAmPI | API2:2023 |
| [04](./docs/scenarios/04-dvga-graphql-introspection.md) | GraphQL introspection + query depth | DVGA | API9:2023 |
| [05](./docs/scenarios/05-crapi-mass-assignment.md) | Mass assignment | crAPI | API6:2023 |

---

## Requirements

- **OS**: Ubuntu 22.04 LTS or 24.04 LTS (amd64 or arm64)
- **RAM**: 8 GB minimum, 16 GB recommended
- **CPU**: 4 cores minimum
- **Disk**: 40 GB minimum, 60 GB recommended
- **Network**: External clients reach the host IP on ports 80/443

---

## Stack

| Layer | Tool | Config |
|---|---|---|
| Cluster | k3d (k3s in Docker) | [`scripts/create-cluster.sh`](./scripts/create-cluster.sh), [`registries.yaml`](./registries.yaml) |
| CNI | k3s flannel (default) · Cilium | [`cni/`](./cni/) |
| Ingress | F5 NGINX Ingress Controller 3.4.3 | [`values/nginx-ingress.yaml`](./values/nginx-ingress.yaml) |
| WAF | NGINX App Protect v4 (Plus only) | [`policies/`](./policies/), [`overlays/`](./overlays/) |
| TLS | cert-manager + local openssl CA | [`manifests/cluster-issuer.yaml`](./manifests/cluster-issuer.yaml) |
| App layout | Kustomize overlays per app | [`base/`](./base/), [`overlays/`](./overlays/) |
| Package mgmt | Helmfile | [`helmfile.yaml`](./helmfile.yaml) |
| Automation | Taskfile | [`Taskfile.yaml`](./Taskfile.yaml) |
| Observability | Prometheus + Grafana + PodMonitor | [`values/prometheus.yaml`](./values/prometheus.yaml), [`grafana/nginx-dashboard.yaml`](./grafana/nginx-dashboard.yaml), [`manifests/nginx-podmonitor.yaml`](./manifests/nginx-podmonitor.yaml) |
| Demo apps | crAPI · Juice Shop · DVGA · VAmPI | [`base/`](./base/) |

---

## Quickstart

First time on a fresh VM:

### 1. Install prerequisites (one-time)

```bash
sudo bash scripts/install-ubuntu.sh
newgrp docker
task check
```

### 2. Configure the lab

```bash
cp lab.env.example lab.env
cp lab.secrets.example lab.secrets
$EDITOR lab.env lab.secrets
```

Key settings in [`lab.env`](./lab.env.example):

```bash
LAB_HOST_IP=172.16.1.136              # IP of this machine
LAB_DOMAIN=lab.local                  # domain for app hostnames
LAB_APPS=crapi juiceshop dvga vampi   # subset to deploy (optional)
NGINX_MODE=oss                        # oss or plus
```

Credentials in [`lab.secrets`](./lab.secrets.example) (gitignored):

```bash
DOCKERHUB_USER=yourusername  # avoids rate limits
NGINX_JWT=                   # required only when NGINX_MODE=plus
```

### 3. Cache images (one-time, requires internet)

```bash
task registry:setup    # creates k3d-registry.localhost:5000 (persistent)
task registry:cache    # pulls every lab image into the registry
```

After this, `task reset` runs fully offline.

### 4. Bring the lab up

```bash
task up
```

Total time on warm cache: ~3 minutes.

### 5. Verify

```bash
task health     # infrastructure + app pod status
task test       # HTTP smoke tests
```

### 6. Client access

On whatever machine you'll use to reach the lab:

```bash
# Add to /etc/hosts
<LAB_HOST_IP>  crapi.<LAB_DOMAIN> juiceshop.<LAB_DOMAIN> dvga.<LAB_DOMAIN> vampi.<LAB_DOMAIN>
```

Install the lab CA so browsers/curl trust the certs — see
[`docs/runbooks/certificate-trust.md`](./docs/runbooks/certificate-trust.md).

---

## Lab URLs

| App | URL | What it is |
|---|---|---|
| crAPI | `https://crapi.<LAB_DOMAIN>` | OWASP API Top 10 |
| Juice Shop | `https://juiceshop.<LAB_DOMAIN>` | OWASP Web Top 10 |
| DVGA | `https://dvga.<LAB_DOMAIN>` | GraphQL vulnerabilities |
| VAmPI | `https://vampi.<LAB_DOMAIN>` | REST API Top 10 |
| Grafana | `http://<LAB_HOST_IP>:3000` | Dashboards (run: `task metrics`) |
| MailHog | `http://<LAB_HOST_IP>:8025` | crAPI email capture (run: `task crapi:mail`) |

---

## Common tasks

`task --list` prints all 42 tasks with descriptions. The ones you'll
use most:

```bash
task up              # full lab up
task down            # destroy cluster (registry survives)
task reset           # down + up
task test            # smoke tests
task metrics         # open Grafana
task locust          # seed users + 5-min traffic generation
task waf-off         # baseline (attacks succeed)
task waf-on          # WAF enabled (enforcement on Plus)
task scan            # GoTestWAF against crAPI
task logs:nginx      # tail ingress access log
task logs:waf        # tail App Protect events (Plus only)
```

---

## Troubleshooting

For a full decision tree, see
[`docs/runbooks/cold-start-recovery.md`](./docs/runbooks/cold-start-recovery.md).
Quick reference for common symptoms:

| Symptom | First thing to try |
|---|---|
| `task up` exits non-zero, apps look fine | Re-run `task health` 30s later — readiness race on old Taskfile versions |
| `task test` returns 502 on some apps | `kubectl get pods -n <ns>` — probably still cold-starting |
| `task test` returns 502 on all apps | Stale iptables PREROUTING DNAT; `sudo iptables -t nat -L PREROUTING -n` |
| Grafana panels show "No data" | `kubectl get podmonitor -n nginx-ingress` — see [observability doc](./docs/architecture/observability.md) |
| Pods evict with `disk-pressure` | Resize VM disk, then `sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2` |
| Locust/scan Pending with "unbound PVC" | `kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'` |
| "NGINX Plus binary found without NGINX Plus flag" | Poisoned registry from a mode switch; `task registry:cache` self-heals. See [ADR 0002](./docs/adr/0002-distinct-registry-paths-for-nic-modes.md) |

---

## CNI options

```bash
task up                  # k3s flannel (default)
CNI=cilium task up       # Cilium (required for BIG-IP ClusterIP mode)
```

See [`cni/`](./cni/) for Cilium config.

---

## BIG-IP CIS integration

```bash
task bigip:configure            # interactive: set mgmt IP + credentials
task bigip:cis:install          # NodePort mode
CIS_MODE=cluster task bigip:cis:install   # ClusterIP mode (requires Cilium)
```

---

## F5 ADSP module mapping

| Module | What the lab covers |
|---|---|
| Module 3 — BIG-IP LTM | CIS integration via [`scripts/install-cis.sh`](./scripts/install-cis.sh) |
| Module 5 — NGINX | Ingress config in [`values/nginx-ingress.yaml`](./values/nginx-ingress.yaml), App Protect policies in [`policies/`](./policies/) |
| Module 6 — Web Security / AWAF | WAF policy tuning; overlay toggle in [`overlays/`](./overlays/) |
| Module 7 — API Security | BOLA, auth bypass, injection — full scenario set in [`docs/scenarios/`](./docs/scenarios/) |

---

## Repo layout

```
nginx-sec-lab/
├── Taskfile.yaml       # all automation
├── helmfile.yaml       # cert-manager, NIC, kube-prometheus-stack
├── registries.yaml     # k3d registry mirror config
├── lab.env.example     # non-sensitive config template
├── lab.secrets.example # credentials template
│
├── scripts/            # install, setup, diagnostic scripts
├── manifests/          # static K8s objects (CA issuer, PodMonitor, namespaces)
├── values/             # Helm chart values (NIC, Prometheus, BIG-IP CIS)
├── grafana/            # dashboard ConfigMaps (auto-loaded by sidecar)
├── policies/           # App Protect policies (used in Plus mode)
├── base/               # per-app Kustomize bases
├── overlays/           # per-app WAF on/off Kustomize overlays
├── jobs/               # one-shot Kubernetes Jobs (scans, Locust, seed)
├── cni/                # CNI alternatives (Cilium)
└── docs/
    ├── scenarios/      # vulnerability walkthroughs
    ├── architecture/   # how the lab is built
    ├── runbooks/       # plus-upgrade, recovery, CA trust
    └── adr/            # Architecture Decision Records
```
