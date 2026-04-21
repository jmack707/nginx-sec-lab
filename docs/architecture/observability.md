# Observability architecture

## Data flow

```
┌─────────────────────────────────────────────────────────────┐
│ NGINX Ingress Controller pod (nginx-ingress namespace)      │
│   • Port 80/443 — client traffic                            │
│   • Port 9113 — /metrics (Prometheus format)                │
│   • Port 8081 — /nginx-ready                                │
└───────────────────────┬─────────────────────────────────────┘
                        │ scraped every 30s
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ PodMonitor  —  manifests/nginx-podmonitor.yaml              │
│   selector:  app.kubernetes.io/name=nginx-ingress           │
│   port:      prometheus  (→ 9113)                           │
│   namespace: nginx-ingress                                  │
└───────────────────────┬─────────────────────────────────────┘
                        │ discovered by Prometheus Operator
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ Prometheus  —  values/prometheus.yaml                       │
│   retention:     24h                                        │
│   selectors:     podMonitorSelectorNilUsesHelmValues=false  │
│                    (watches ALL PodMonitors cluster-wide)   │
│   storage:       emptyDir (data does not persist restart)   │
└───────────────────────┬─────────────────────────────────────┘
                        │ queried by Grafana datasource
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ Grafana  —  preconfigured via kube-prometheus-stack         │
│   dashboards: nginx-lab-dashboard, nginx-lab-dashboard-plus │
│     loaded by sidecar from ConfigMaps labeled               │
│     grafana_dashboard="1"                                   │
│   source:    grafana/nginx-dashboard.yaml                   │
└─────────────────────────────────────────────────────────────┘
```

Access:

```bash
task metrics      # port-forward Grafana to localhost:3000
task prometheus   # port-forward Prometheus to localhost:9090
```

## Why a static PodMonitor, not a chart-driven ServiceMonitor?

Previous versions of this lab used the F5 NIC Helm chart's built-in
`controller.prometheus.serviceMonitor.create` option. It didn't render
a ServiceMonitor on chart 1.1.3 — the template either requires an
accompanying separate metrics Service or silently skips when some
precondition isn't met. The result was empty Grafana panels.

A static PodMonitor manifest has no chart-version coupling, targets
pods directly (so the intermediate Service isn't needed), and survives
NIC chart upgrades without redaction. Prometheus Operator treats
PodMonitor and ServiceMonitor symmetrically, so there's no operational
difference from the monitoring side.

See [ADR 0001](../adr/0001-podmonitor-over-chart-servicemonitor.md) for
the full reasoning.

## Why `Nil` + `false` on the selector flags?

`kube-prometheus-stack` ships two settings in
[`values/prometheus.yaml`](../../values/prometheus.yaml):

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
podMonitorSelectorNilUsesHelmValues:     false
```

Translation: when the Prometheus CR has a `nil` selector, Prometheus
defaults to watching only monitors it created itself (via the chart's
own Helm values). Setting these to `false` tells it to instead watch
**everything cluster-wide**. Without this, our PodMonitor in the
`nginx-ingress` namespace is invisible to a Prometheus in the
`monitoring` namespace.

## The two dashboards

[`grafana/nginx-dashboard.yaml`](../../grafana/nginx-dashboard.yaml)
ships two dashboards, both auto-loaded by the Grafana sidecar:

### NGINX Security Lab — OSS

Panels driven by metrics that exist on F5 NIC in OSS mode (derived from
`stub_status`). These are global counters — no per-host or per-status
labels.

| Panel | Query (simplified) | What it tells you |
|---|---|---|
| NGINX Status | `max(nginx_ingress_controller_nginx_last_reload_status)` | OK/FAIL of the last config reload |
| Last Reload Duration | `nginx_ingress_controller_nginx_last_reload_milliseconds` | Reload latency; rising = churn |
| Reload Errors (10m) | `increase(nginx_ingress_controller_nginx_reload_errors_total[10m])` | Should always be zero |
| Worker Processes | `sum(nginx_ingress_controller_nginx_worker_processes_total)` | Doubles briefly during reloads |
| Total Request Rate | `sum(rate(nginx_ingress_nginx_http_requests_total[2m]))` | Aggregate traffic (no per-app split in OSS) |
| Connection States | `nginx_ingress_nginx_connections_{active,reading,writing,waiting}` | Backpressure indicators |
| Connection Throughput | `rate(nginx_ingress_nginx_connections_{accepted,handled}[2m])` | Gap = dropped connections |
| Config Reload Activity | `rate(nginx_ingress_controller_nginx_reloads_total[5m]) by (reason)` | `endpoints` vs `other` reload reasons |

### NGINX Security Lab — Plus

Panels driven by NGINX Plus API metrics (per server_zone, per upstream).
These **do not exist in OSS** — panels show "No data" until the lab
switches to `NGINX_MODE=plus`.

| Panel | Metric | What it adds |
|---|---|---|
| Request Rate by App | `nginx_ingress_nginx_server_zone_requests` by `server_zone` | Per-ingress breakdown |
| Responses by App and Code | `nginx_ingress_nginx_server_zone_responses` by `server_zone, code` | 4xx/5xx per app — the WAF block visualization |
| Throughput by App | `nginx_ingress_nginx_server_zone_{received,sent}` | Bytes per ingress |
| Discarded Requests | `nginx_ingress_nginx_server_zone_discarded` | Client disconnects, timeouts |

The Plus dashboard is the primary payoff of upgrading. Per-app 4xx
visualization lets you watch attacks against one app while others stay
quiet — something the OSS dashboard fundamentally cannot show.

## Extending

### Adding a new scrape target

Static PodMonitor pattern — copy
[`manifests/nginx-podmonitor.yaml`](../../manifests/nginx-podmonitor.yaml)
and adjust selector + port. Apply to the cluster; Prometheus Operator
picks it up within ~30s.

### Adding a dashboard panel

Edit the ConfigMap data section in
[`grafana/nginx-dashboard.yaml`](../../grafana/nginx-dashboard.yaml).
The sidecar hot-loads changes — no Grafana pod restart. Worst case:
hard-refresh the browser.

### Adding a whole new dashboard

Append a third ConfigMap to `grafana/nginx-dashboard.yaml` with the
same `grafana_dashboard: "1"` label. The sidecar loads them all.

### Longer retention

Bump `retention: 24h` in [`values/prometheus.yaml`](../../values/prometheus.yaml).
Default `emptyDir` storage vanishes on pod restart regardless — for
persistence across restarts, add a `storageSpec` block with a PVC.
