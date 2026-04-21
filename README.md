# nginx-sec-lab

A fully repeatable Kubernetes security lab using k3d (k3s in Docker),
F5 NGINX Ingress Controller, and four intentionally vulnerable demo
applications. Built for F5 ADSP training and NGINX security experimentation.

**What you get after `task up`:**

- A three-node k3d cluster running crAPI, Juice Shop, DVGA, and VAmPI behind
  NGINX Ingress with TLS from a local CA.
- A Kustomize-driven WAF toggle (`task waf-on` / `task waf-off`) that works
  today in shadow mode on OSS and enforces on NGINX Plus.
- Prometheus + Grafana with two purpose-built dashboards (OSS metrics and
  Plus metrics), scraped via a static PodMonitor.
- Repeatable scan workflows (GoTestWAF, Nuclei) and realistic traffic
  generation (Locust) wired into the lab.

Everything is driven from [`Taskfile.yaml`](./Taskfile.yaml) — no
kubectl-golf required.

---

## Documentation

| What you want to do | Where to go |
|---|---|
| **Get the lab running** | [Quickstart](#quickstart) below |
| **Work through a vulnerability scenario** | [`docs/scenarios/`](./docs/scenarios/) — 5 hands-on walkthroughs |
| **Understand how the lab is built** | [`docs/architecture/`](./docs/architecture/) — observability, WAF toggle, image layers |
| **Recover from a broken state** | [`docs/runbooks/cold-start-recovery.md`](./docs/runbooks/cold-start-recovery.md) |
| **Upgrade to NGINX Plus** | [`docs/runbooks/plus-upgrade.md`](./docs/runbooks/plus-upgrade.md) |
| **Install the lab CA on clients** | [`docs/runbooks/certificate-trust.md`](./docs/runbooks/certificate-trust.md) |
| **See why a design decision was made** | [`docs/adr/`](./docs/adr/) — Architecture Decision Records |

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

If pods evict with `disk-pressure` taint: resize the VM disk, then
`sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2`.

---

## Stack

| Layer | Tool | Config lives in |
|---|---|---|
| Cluster | k3d (k3s in Docker) | [`scripts/create-cluster.sh`](./scripts/create-cluster.sh), [`registries.yaml`](./registries.yaml) |
| CNI | k3s flannel (default) · Cilium | [`scripts/install-cni.sh`](./scripts/install-cni.sh), [`cni/`](./cni/) |
| Ingress | F5 NGINX Ingress Controller 3.4.3 | [`values/nginx-ingress.yaml`](./values/nginx-ingress.yaml) |
| WAF | NGINX App Protect v4 (Plus only) | [`policies/`](./policies/), [`overlays/<app>/waf-enabled/`](./overlays/) |
| TLS | cert-manager + local openssl CA | [`manifests/cluster-issuer.yaml`](./manifests/cluster-issuer.yaml), [`scripts/pre-deploy.sh`](./scripts/pre-deploy.sh) |
| App layout | Kustomize overlays per app | [`base/`](./base/), [`overlays/`](./overlays/) |
| Package mgmt | Helmfile | [`helmfile.yaml`](./helmfile.yaml) |
| Automation | Taskfile (go-task) | [`Taskfile.yaml`](./Taskfile.yaml) |
| Observability | Prometheus + Grafana + PodMonitor | [`values/prometheus.yaml`](./values/prometheus.yaml), [`grafana/nginx-dashboard.yaml`](./grafana/nginx-dashboard.yaml), [`manifests/nginx-podmonitor.yaml`](./manifests/nginx-podmonitor.yaml) |
| Demo apps | crAPI · Juice Shop · DVGA · VAmPI | [`base/<app>/`](./base/) |

---

## Quickstart

Follow these steps the first time on a fresh VM. Subsequent runs skip to
step 4 (`task up`).

### 1. Install prerequisites (one-time)

```bash
sudo bash scripts/install-ubuntu.sh
newgrp docker
task check
```

Installs Docker, kubectl, k3d, Helm, Helmfile, go-task, and step-cli.
See [`scripts/install-ubuntu.sh`](./scripts/install-ubuntu.sh) and
[`scripts/check-prereqs.sh`](./scripts/check-prereqs.sh). `task check`
exits non-zero if anything is missing.

### 2. Configure the lab

```bash
cp lab.env.example lab.env             # if not already present
cp lab.secrets.example lab.secrets
$EDITOR lab.env lab.secrets
```

Key settings in [`lab.env`](./lab.env.example):

```bash
LAB_HOST_IP=172.16.1.136     # IP of this Ubuntu machine
LAB_DOMAIN=lab.local         # domain for all app hostnames
LAB_APPS=crapi juiceshop dvga vampi   # subset of apps to deploy
NGINX_MODE=oss               # oss or plus
```

Credentials live in [`lab.secrets`](./lab.secrets.example) (gitignored):

```bash
DOCKERHUB_USER=yourusername  # avoids anonymous-pull rate limits
DOCKERHUB_PASS=...           # optional, enables non-interactive login
NGINX_JWT=                   # required only when NGINX_MODE=plus
```

### 3. Cache all images locally (one-time, requires internet)

```bash
task registry:setup    # creates k3d-registry.localhost:5000 (survives resets)
task registry:cache    # pulls every image the lab needs into the registry
```

After this, `task reset` runs fully offline. See
[`scripts/setup-registry.sh`](./scripts/setup-registry.sh) and
[`scripts/pull-and-cache.sh`](./scripts/pull-and-cache.sh).

### 4. Bring the lab up

```bash
task up
```

This runs the full pipeline end-to-end: cluster creation, CNI install,
image import, Helm deploys, WAF policies, demo apps, and a readiness wait
before `task health` snapshots the final state. Total time on a warm
cache: ~3 minutes.

### 5. Verify

```bash
task health           # infrastructure + app pod status
task test             # HTTP smoke tests against every endpoint
```

Expected output from `task test`: all four apps return HTTP 200 at their
root, crAPI API endpoints return 200/401 correctly, and DVGA's GraphQL
endpoint returns 200.

### 6. Add client hosts entry

Wherever you're running curl or a browser, point the app hostnames at the
lab IP:

```
<LAB_HOST_IP>  crapi.<LAB_DOMAIN> juiceshop.<LAB_DOMAIN> dvga.<LAB_DOMAIN> vampi.<LAB_DOMAIN>
```

Then install the local CA so browsers trust the lab certs:

| Platform | Command |
|---|---|
| Linux | `sudo cp root_ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root_ca.crt` |
| Windows | `certutil -addstore -f "ROOT" root_ca.crt` |

---

## Lab URLs

| App | URL | What it is |
|---|---|---|
| crAPI | `https://crapi.<LAB_DOMAIN>` | OWASP API Top 10 — BOLA, auth bypass, injection |
| Juice Shop | `https://juiceshop.<LAB_DOMAIN>` | OWASP Web Top 10 |
| DVGA | `https://dvga.<LAB_DOMAIN>` | GraphQL vulnerabilities |
| VAmPI | `https://vampi.<LAB_DOMAIN>` | REST API Top 10 (SQLi, BOLA, JWT bypass) |
| Grafana | `http://<LAB_HOST_IP>:3000` | Dashboards (run: `task metrics`) |
| MailHog | `http://<LAB_HOST_IP>:8025` | crAPI email capture (run: `task crapi:mail`) |

All app TLS certificates are signed by the local CA (`root_ca.crt` in the
repo root, created by `task ca:init` on first `task up`).

---

## Scenarios

Each scenario produces a distinct shape on the Grafana OSS dashboard.
Open it in a second browser tab (`task metrics` → `http://localhost:3000`
→ **Dashboards → NGINX Lab → NGINX Security Lab — OSS**) before running
them.

### Baseline traffic — `task locust`

Seeds three test users in crAPI, then spins up a
[Locust traffic-generation Job](./jobs/locust-job.yaml) that simulates 20
users browsing the shop, community, and workshop endpoints for 5 minutes.

```bash
task locust
task locust:logs      # in another terminal, per-endpoint stats
```

On the dashboard: *Total Request Rate* climbs to ~20-40 req/s, *Connection
States* shows `active` near 20 (matching user count), accepted and handled
stay overlaid. The end-of-run cliff back to zero is the clearest visual of
"everything is wired up end-to-end."

### Attacks succeed — `task waf-off && task scan`

```bash
task waf-off                   # baseline overlays (no WAF annotation)
task scan                      # GoTestWAF against crAPI
```

Fires several thousand crafted attack strings (SQLi, XSS, LFI, shell
injection) at crAPI. Most succeed. Record the GoTestWAF score — this is
the "before" half of the WAF story.

On the dashboard: request-rate spikes much higher and spikier than Locust.
In a second terminal, `task logs:nginx` shows HTTP 200 responses to
obviously hostile paths — the "attack succeeded" signal.

### Attacks blocked — `task waf-on && task scan`

```bash
task waf-on
task scan
```

Applies the `waf-enabled` Kustomize overlay to every app in `LAB_APPS`.
Overlay sources live under [`overlays/<app>/waf-enabled/`](./overlays/).
On **NGINX Plus** this attaches App Protect policies from
[`policies/`](./policies/) and real enforcement kicks in — expect to see
HTTP 400/403 responses in `task logs:waf` and a dramatic score improvement
in the GoTestWAF report.

On **OSS**, `waf-on` is a shadow toggle: the overlay applies, but no
enforcement happens (App Protect is Plus-only). Useful for testing the
overlay-switching mechanism itself.

### Nuclei template scan — `task scan:nuclei`

Slower than GoTestWAF but tests a much wider surface: CVE templates,
misconfiguration checks, default credentials. Runs across all four apps.
Report lands on the shared PVC.

### Other useful commands

```bash
task crapi:mail       # intercept crAPI password-reset tokens at MailHog
task crapi:shell      # shell into crapi-identity for debugging
task prometheus       # open Prometheus UI at localhost:9090
task logs:waf         # tail App Protect security events (Plus only)
```

---

## How observability works

Metrics flow:

```
NIC pod :9113/metrics
    ↓ (scraped every 30s)
PodMonitor  ← manifests/nginx-podmonitor.yaml
    ↓ (discovered by Prometheus Operator)
Prometheus  ← values/prometheus.yaml
    ↓ (queried by Grafana)
Grafana dashboards  ← grafana/nginx-dashboard.yaml
```

The [PodMonitor](./manifests/nginx-podmonitor.yaml) is applied as a
plain manifest rather than relying on the NIC chart's built-in
ServiceMonitor option — the chart's serviceMonitor values don't render
reliably in chart 1.1.3, and a static PodMonitor is self-contained and
survives chart upgrades.

Two dashboards ship, both auto-loaded by the Grafana sidecar:

- **NGINX Security Lab — OSS** — uses stub_status-derived metrics that
  exist in OSS mode (request rate, connection states, reload health).
- **NGINX Security Lab — Plus** — uses server-zone metrics for per-ingress
  request rate, response codes, throughput. Panels show "No data" until
  you switch to `NGINX_MODE=plus`.

Dashboard source: [`grafana/nginx-dashboard.yaml`](./grafana/nginx-dashboard.yaml).

---

## Upgrading to NGINX Plus

Shadow-mode OSS is fine for testing the lab mechanics. Real WAF enforcement
requires NGINX Plus, which needs a JWT from your F5 subscription:

```bash
# 1. Add token to lab.secrets (never commit this file)
echo "NGINX_JWT=<paste-token>" >> lab.secrets

# 2. Flip mode
sed -i 's/^NGINX_MODE=oss/NGINX_MODE=plus/' lab.env

# 3. Re-cache the Plus image (lands at a distinct registry path,
#    won't collide with the OSS image)
task registry:cache

# 4. Rebuild
task reset
```

---

## Tear down

```bash
task down     # delete cluster; registry and cached images survive
task reset    # task down + task up
```

The local registry (`k3d-registry.localhost:5000`) is intentionally
long-lived. It's a separate Docker container created by
[`scripts/setup-registry.sh`](./scripts/setup-registry.sh) and isn't
touched by `task down`.

---

## CNI options

| Command | CNI | Notes |
|---|---|---|
| `task up` | k3s flannel (default) | Simplest setup, works out of the box |
| `CNI=cilium task up` | Cilium | Required for BIG-IP ClusterIP mode; enables Hubble UI |

Cilium config: [`cni/cilium/values-base.yaml`](./cni/cilium/values-base.yaml).
Switch between them any time; `task reset` picks up the new `CNI` env var.

---

## BIG-IP CIS integration

```bash
task bigip:configure              # interactive: set mgmt IP + credentials
task bigip:cis:install            # NodePort mode (default)
CIS_MODE=cluster task bigip:cis:install   # ClusterIP mode (requires Cilium)
```

See [`scripts/install-cis.sh`](./scripts/install-cis.sh) and
[`scripts/bigip-configure.sh`](./scripts/bigip-configure.sh).

---

## Troubleshooting

For a decision tree and full diagnostic flow, see
[`docs/runbooks/cold-start-recovery.md`](./docs/runbooks/cold-start-recovery.md).
The most common issues:

| Symptom | First thing to try |
|---|---|
| `task up` exits non-zero, but apps look fine | Re-run `task health` 30 seconds later — usually a readiness race on very old Taskfile versions |
| `task test` returns 502 on some apps | `kubectl get pods -n <ns>` — probably still cold-starting or an upstream Service port mismatch |
| `task test` returns 502 on all apps | Stale iptables PREROUTING DNAT from a previous deploy; `sudo iptables -t nat -L PREROUTING -n` |
| Grafana panels show "No data" | `kubectl get podmonitor -n nginx-ingress` — confirm it exists; see [observability architecture](./docs/architecture/observability.md) |
| Pods evict with `disk-pressure` | VM disk full — resize, then `sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2` |
| Locust/scan Pending with "unbound PVC" | No default StorageClass — `kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'` |
| "NGINX Plus binary found without NGINX Plus flag" | Poisoned registry from a previous mode switch; `task registry:cache` self-heals. See [ADR 0002](./docs/adr/0002-distinct-registry-paths-for-nic-modes.md) |

---

## Task reference

`task --list` prints all tasks with descriptions. Grouped here by
workflow:

### Lifecycle

```bash
task up              # full lab up (reads lab.env for IP/domain)
task down            # destroy cluster (registry survives)
task reset           # down + up
task check           # verify prerequisites
task health          # post-deploy verification
task test            # curl smoke tests
```

### Registry (one-time, then cached)

```bash
task registry:setup  # create local k3d registry
task registry:cache  # pull and cache all images
task registry:ls     # list cached images
```

### Lab scenarios

```bash
task waf-on          # enable App Protect WAF overlay
task waf-off         # disable WAF (baseline)
task scan            # GoTestWAF against crAPI
task scan:nuclei     # Nuclei scan across all apps
task locust          # seed users + 5-min traffic generation
task locust:logs     # follow Locust stats
```

### Observability

```bash
task metrics         # port-forward Grafana to :3000
task prometheus      # port-forward Prometheus to :9090
task logs:waf        # tail App Protect events (Plus only)
task logs:nginx      # tail NGINX Ingress access log
task grafana:dashboard  # re-apply dashboard ConfigMaps
```

### Demo apps

```bash
task apps:up         # deploy LAB_APPS (waits for readiness)
task apps:down       # remove LAB_APPS namespaces
task crapi:seed      # register test users in crAPI
task crapi:mail      # port-forward MailHog to :8025
task crapi:shell     # shell into crapi-identity
task juiceshop:shell # shell into juice-shop
```

### CNI / BIG-IP

```bash
task cni:install     # install CNI (default kindnet; CNI=cilium for Cilium)
task cni:status      # show CNI status and node assignments
task cni:hubble      # port-forward Hubble UI (Cilium only)
task bigip:configure       # interactive BIG-IP setup
task bigip:cis:install     # install BIG-IP CIS
task bigip:cis:status      # CIS pod status + logs
```

---

## F5 ADSP module mapping

| Module | What the lab covers |
|---|---|
| Module 3 — BIG-IP LTM | Pool members, persistence, iRules against crAPI via [`scripts/install-cis.sh`](./scripts/install-cis.sh) |
| Module 5 — NGINX | Ingress config, VirtualServer CRDs, App Protect via [`values/nginx-ingress.yaml`](./values/nginx-ingress.yaml) and [`policies/`](./policies/) |
| Module 6 — Web Security / AWAF | WAF policy tuning against crAPI/DVGA/Juice Shop; overlay toggle in [`overlays/`](./overlays/) |
| Module 7 — API Security | BOLA, auth bypass, injection — full crAPI challenge set plus VAmPI |

---

## Repo layout

```
nginx-sec-lab/
├── lab.env.example             # non-sensitive config template
├── lab.secrets.example         # credentials template (gitignore your copy)
├── Taskfile.yaml               # all automation
├── helmfile.yaml               # cert-manager, NIC, kube-prometheus-stack
├── registries.yaml             # k3d registry mirror config
│
├── scripts/                    # install, setup, diagnostic scripts
├── manifests/                  # static K8s objects (CA issuer, PodMonitor, namespaces)
├── values/                     # Helm chart values (NIC, Prometheus, BIG-IP CIS)
├── grafana/                    # dashboard ConfigMaps (auto-loaded by sidecar)
├── policies/                   # App Protect policies (used in Plus mode)
├── base/                       # per-app Kustomize bases
├── overlays/                   # per-app WAF on/off Kustomize overlays
├── jobs/                       # one-shot Kubernetes Jobs (scans, Locust, seed)
├── cni/                        # CNI alternatives (Cilium)
└── docs/
    ├── scenarios/              # vulnerability walkthroughs (hands-on)
    ├── architecture/           # how the lab is built (explanations)
    ├── runbooks/               # plus-upgrade, cold-start recovery, CA trust
    └── adr/                    # Architecture Decision Records
```