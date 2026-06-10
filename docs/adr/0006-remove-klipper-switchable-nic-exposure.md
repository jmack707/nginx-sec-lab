# ADR 0006 — Remove Klipper; switchable NIC service exposure for BIG-IP

**Status:** Accepted
**Date:** 2026-06
**Supersedes:** the `type: LoadBalancer` NIC service from the original setup

---

## Context

The lab originally exposed the NGINX Ingress Controller (NIC) as a
`type: LoadBalancer` service. On k3d this works because k3s ships
**Klipper** (the built-in ServiceLB controller), which assigns the
LoadBalancer an external IP via `svclb-*` host-port DaemonSet pods.

Once BIG-IP CIS enters the picture, Klipper and BIG-IP are both trying
to be the load balancer. Two concrete problems resulted:

1. **Intermittent NIC + CIS NodePort behaviour.** NIC has a single
   replica and the service used `externalTrafficPolicy: Local`. CIS in
   NodePort mode registers every node IP as a pool member, but `Local`
   only forwards NodePort traffic to a NIC pod co-located on the same
   node. Two of three pool members blackholed traffic, so requests
   failed roughly two-thirds of the time — appearing random.

2. **Mode mismatches.** Nothing enforced that the NIC service type and
   the CIS `pool_member_type` agree. A ClusterIP NIC with CIS NodePort
   (no NodePort to target) or a NodePort NIC with CIS cluster mode
   (no VTEP) both fail, intermittently or completely.

The user needs to run NIC and CIS in either NodePort or ClusterIP mode
and switch between them, with the two staying consistent.

## Decision

Three coordinated changes:

1. **Disable Klipper.** Add `--disable=servicelb@server:0` to the k3d
   cluster creation args in `scripts/create-cluster.sh`. BIG-IP CIS is
   now the only load balancer. This does **not** remove the k3d
   serverlb container (k3d's host-port proxy), which is still required
   for host access.

2. **Make the NIC service type switchable.** Drive
   `controller.service.type` from `NIC_SVC_MODE` in `lab.env`
   (`nodeport` | `clusterip`) via a helmfile template `set:` on the
   nginx-ingress release. Runtime switch tasks (`nic:nodeport`,
   `nic:clusterip`) re-sync only the NIC release. NodePorts are pinned
   (HTTP 30000, HTTPS 30443) so BIG-IP pool members and the host-port
   proxy stay stable.

3. **Set `externalTrafficPolicy: Cluster`** on the NIC service. This
   removes the single-replica NodePort blackhole and is the actual fix
   for the intermittent failures. Source IP is already SNAT'd by BIG-IP,
   so `Local` provided no benefit in this topology.

The valid pairings are documented in
[`docs/architecture/nic-cis-exposure-matrix.md`](../architecture/nic-cis-exposure-matrix.md)
and enforced by convention:

| `NIC_SVC_MODE` | `CIS_MODE` | CNI |
|---|---|---|
| `nodeport` | `nodeport` | any |
| `clusterip` | `cluster` | Cilium + VTEP |

## Consequences

### Positive

- NIC + CIS NodePort works reliably (no more 2-of-3 failures).
- NIC mode and CIS mode are both first-class, switchable, and
  documented as a pair.
- `type: LoadBalancer` / `<pending>` confusion is gone.
- Host `:80/:443` testing still works in NodePort mode because the k3d
  serverlb proxies those to the NIC NodePorts.

### Negative / costs

- **ClusterIP mode loses host access.** With Klipper gone and NIC as
  ClusterIP, host `:80/:443` reach no NodePort. BIG-IP via the VTEP
  tunnel is the only ingress path. `task test` against `LAB_HOST_IP`
  will not pass in ClusterIP mode. This is inherent to the topology,
  not a regression.
- **`externalTrafficPolicy: Cluster` SNATs the source IP.** Acceptable
  because BIG-IP already replaced the client IP upstream. If true
  client IP is ever needed, use BIG-IP X-Forwarded-For insertion
  rather than reverting to `Local`.
- **NIC NodePorts are now fixed values** (30000/30443) bound at cluster
  creation. Changing them needs a `values/nginx-ingress.yaml` edit and
  `task reset`.

## Alternatives considered

- **Keep Klipper, add CIS alongside.** Rejected — two load balancers
  competing was the source of the intermittent behaviour.
- **Scale NIC to a DaemonSet so `Local` works.** Viable, but heavier
  than needed for a single-VM lab and doesn't address mode pairing.
- **kubectl patch the service type at runtime.** Rejected per the same
  declarative-source-of-truth rationale as ADR 0003/0005. helmfile
  remains the source of truth for the NIC release.
