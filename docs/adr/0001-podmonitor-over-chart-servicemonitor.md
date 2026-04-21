# ADR 0001 — PodMonitor instead of chart-driven ServiceMonitor

**Status:** Accepted

**Date:** 2026-04

## Context

The F5 NGINX Ingress Controller Helm chart (nginx-stable/nginx-ingress)
exposes several values for Prometheus integration:

```yaml
controller:
  prometheus:
    create: true
    port: 9113
    serviceMonitor:
      create: true     # ← the option that should create a ServiceMonitor
```

On chart version **1.1.3** (shipped with NIC 3.4.3), setting
`serviceMonitor.create: true` does not reliably produce a ServiceMonitor
resource. The chart's template expects a separate metrics-only Service
to exist first (controlled by `prometheus.service.create`), the
ServiceMonitor selector then targets that Service, and the wiring falls
apart if either half is misconfigured.

Two real failure modes observed during lab development:

1. `serviceMonitor.create: true` at the `controller.*` path (wrong — the
   chart expects it nested under `prometheus.*`). Silently ignored by
   Helm; zero feedback.
2. `prometheus.serviceMonitor.create: true` with no accompanying
   `prometheus.service.create: true`. Chart renders a ServiceMonitor
   that selects a Service that doesn't exist. Prometheus sees the
   monitor but has no endpoints to scrape.

## Decision

Ship a static [`manifests/nginx-podmonitor.yaml`](../../manifests/nginx-podmonitor.yaml)
that targets the NIC pods directly via their pod labels. Apply it as
part of the `task issuer` step, alongside the ClusterIssuer and App
Protect policies.

## Consequences

### Positive

- **No chart-version coupling.** Chart upgrades cannot silently break
  observability wiring.
- **Fewer moving parts.** One fewer Service in the cluster; one fewer
  chart-values path to debug.
- **Self-contained and auditable.** The PodMonitor YAML states exactly
  which labels it selects and which port it scrapes. No template
  indirection.
- **Works identically in OSS and Plus.** The pod labels and metrics
  port are the same in both modes.

### Negative / costs

- **We now own the PodMonitor definition.** If NIC changes its pod
  labels in a future release (label stability is not guaranteed), the
  PodMonitor's selector needs updating. Mitigation: the file has a
  comment block documenting the verification command.
- **Contributors setting up similar labs won't find this in F5's
  documentation.** F5 docs describe the chart-values approach. The
  README's "How observability works" section documents our divergence
  and links this ADR.

### Requirements on cluster config

For the PodMonitor to be discovered cluster-wide, Prometheus must be
configured to watch all PodMonitors, not just those in its own
namespace or matching its own labels:

```yaml
# values/prometheus.yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
```

Both settings must be `false`. Forgetting one is silent failure.

## Alternatives considered

- **Fix the chart values.** Attempted and failed across multiple value
  paths. Even when the chart rendered a ServiceMonitor correctly, the
  coupling to the two-Service pattern added fragility.
- **Upstream a fix to the F5 chart.** Out of scope for a training lab.
  Users can't be expected to wait on chart releases.
- **Static ServiceMonitor instead of PodMonitor.** Either works;
  PodMonitor removes the intermediate Service (which we don't otherwise
  need), so it's one fewer object.

## Related

- [architecture/observability.md](../architecture/observability.md) —
  full data-flow diagram.
- Session debugging trail that led to this decision — the chart-values
  path was tried and abandoned before committing to the static
  manifest.
