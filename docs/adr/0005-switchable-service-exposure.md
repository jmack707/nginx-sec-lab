# ADR 0005 — Switchable service exposure: ClusterIP and NodePort

**Status:** Accepted  
**Date:** 2025-01  
**Deciders:** Lab maintainer

---

## Context

Demo app Services were ClusterIP-only at launch. External access to the
apps required the full NIC ingress path (TLS, hostname-based routing).
This created two friction points:

1. **Scan tools** (GoTestWAF, Nuclei, manual curl with raw HTTP) need a
   plain HTTP endpoint. Working around this required either scan jobs
   inside the cluster (with `hostAliases`) or per-session `kubectl
   port-forward` tunnels that don't survive shell reconnects.

2. **BIG-IP CIS NodePort mode** expects to pool-member against
   `<node-ip>:<nodePort>`. Without NodePort Services, CIS NodePort mode
   has no target to send traffic to.

At the same time, WAF toggle scenarios, TLS certificate testing, and
Ingress annotation work all require the NIC path to remain active.
Forcing a permanent choice between the two modes would break either the
scan workflow or the NIC workflow.

---

## Decision

Introduce a **switchable service exposure mode** driven by:

- A `SVC_MODE=clusterip|nodeport` variable in `lab.env`
- A pair of Kustomize overlays per app:
  - `overlays/<app>/svc-nodeport/kustomization.yaml` — patches the
    front-facing Service to `type: NodePort` with a pinned `nodePort`
  - `overlays/<app>/svc-clusterip/kustomization.yaml` — patches it back
    to `type: ClusterIP` (removing the `nodePort` field)
- A `scripts/svc-mode.sh nodeport|clusterip` script that applies the
  correct overlay for each app in `LAB_APPS`
- Three Taskfile tasks: `svc:nodeport`, `svc:clusterip`, `svc:status`
- A NodePort range `30080-30600` bound at cluster creation in
  `scripts/create-cluster.sh` so the ports are accessible from the host

The switch is **live** — `kubectl apply -k` on a Service does not
restart pods. The NIC ingress path (HTTPS, hostname-based) remains
fully functional while NodePort is active; both paths work
simultaneously.

### NodePort assignments

| App | NodePort | Access |
|-----|----------|--------|
| crapi (crapi-web) | 30080 | `http://<LAB_HOST_IP>:30080` |
| juice-shop | 30300 | `http://<LAB_HOST_IP>:30300` |
| dvga | 30501 | `http://<LAB_HOST_IP>:30501` |
| vampi | 30082 | `http://<LAB_HOST_IP>:30082` |

Ports are pinned (not ephemeral) so scan job configs and BIG-IP pool
member definitions remain stable across re-applies.

For crAPI specifically, only `crapi-web` (port 80) receives the NodePort
patch. Internal services (`crapi-identity`, `crapi-community`,
`crapi-workshop`, `crapi-postgres`, `crapi-mongodb`) stay ClusterIP —
they are not intended for direct external access.

---

## Consequences

**Positive:**
- Scan tools can target `http://<host>:<port>` without SNI or TLS
  configuration, removing the need for in-cluster scan Job workarounds.
- BIG-IP CIS NodePort mode has stable pool-member targets.
- The switch is zero-downtime and idempotent (re-applying the same
  overlay is safe).
- `task svc:status` shows the current type and access URL for all apps
  at a glance.
- Both modes coexist — NIC path is not disrupted by NodePort activation.

**Negative / trade-offs:**
- The NodePort range (`30080-30600`) is bound at cluster creation time.
  Adding new ports outside this range requires `task reset` (cluster
  rebuild). The range is wide enough to accommodate future apps.
- The `svc-clusterip` overlay uses a JSON Patch `remove` operation on
  `spec.ports[0].nodePort`. If the Service is already ClusterIP (no
  `nodePort` field present), Kubernetes accepts the apply without error
  (the field simply doesn't exist to remove), so re-applying
  `svc-clusterip` is always safe.
- `SVC_MODE` in `lab.env` documents intent but does not auto-apply on
  `task apps:up`. The `apps:up` task applies the WAF overlay
  (`waf-disabled`), which does not include a Service type patch — the
  Service type is therefore whatever was last applied via
  `svc:nodeport` or `svc:clusterip`. This is intentional: WAF state and
  Service exposure are orthogonal concerns and should be toggled
  independently.

---

## Alternatives considered

**Permanent NodePort in base manifests**  
Rejected. It would require every operator to bind the port range and
would make the base harder to use in environments where NodePort isn't
needed. ClusterIP is the safer default.

**`kubectl patch` script at runtime**  
Rejected per the same rationale as ADR 0003 (WAF toggle). Imperative
patches leave cluster state that doesn't match any file in the repo.
Kustomize overlays are declarative and git-trackable.

**ExternalIPs on the Service**  
Rejected. ExternalIPs require the host IP to be configured on a cluster
node interface, which is fragile in k3d (Docker containers). NodePort
via the k3d LoadBalancer binding is simpler and more reliable.
