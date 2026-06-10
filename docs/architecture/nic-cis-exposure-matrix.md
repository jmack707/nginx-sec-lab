# NIC + BIG-IP CIS exposure matrix

This is the single most important reference for getting NGINX Ingress
(NIC) and BIG-IP CIS to work together reliably. The two have to be
**paired** — the NIC Kubernetes Service type must match the CIS
`pool_member_type`. Mismatches are the cause of "it works sometimes."

## The pairing rule

| NIC `service.type` | CIS `pool_member_type` | CNI required | BIG-IP pool members | Status |
|---|---|---|---|---|
| `NodePort` (+ `ETP: Cluster`) | `nodeport` | any (kindnet / flannel / Cilium) | `<node-ip>:<nodePort>` | ✅ Recommended |
| `ClusterIP` | `cluster` | Cilium + BIG-IP VTEP | NIC pod IPs | ✅ Advanced |
| `NodePort` (`ETP: Local`) | `nodeport` | any | `<node-ip>:<nodePort>` | ⚠️ Intermittent — see below |
| `ClusterIP` | `nodeport` | — | (no NodePort exists) | ❌ Broken |
| `NodePort` | `cluster` | Cilium + VTEP | pod IPs (NodePort unused) | ❌ Mismatch |
| `LoadBalancer` (Klipper) | `nodeport` | any | `<node-ip>:<nodePort>` | ⚠️ Klipper races CIS; LB stays `<pending>` once Klipper is removed |

Only the first two rows are supported configurations in this lab.

## Set the pairing in two places

`lab.env`:

```bash
NIC_SVC_MODE=nodeport      # or clusterip
```

CIS install:

```bash
task bigip:cis:install CIS_MODE=nodeport     # pair with NIC_SVC_MODE=nodeport
task bigip:cis:install CIS_MODE=cluster      # pair with NIC_SVC_MODE=clusterip
```

Switch NIC at runtime without a rebuild:

```bash
task nic:nodeport     # re-syncs the NIC release as NodePort
task nic:clusterip    # re-syncs the NIC release as ClusterIP
task nic:status       # shows current type, NodePorts, pod placement, node IPs
```

## Why `externalTrafficPolicy: Cluster` matters

This is the fix for the most common intermittent failure.

NIC runs a **single replica**, so its pod lives on exactly one of the
three k3d nodes. CIS in NodePort mode registers **all** node IPs as
BIG-IP pool members.

- With `externalTrafficPolicy: Local`, a node only forwards NodePort
  traffic to a NIC pod **running on that same node**. Two of the three
  pool members have no local NIC pod, so they silently drop the
  connection. BIG-IP load-balances across all three → ~2 of 3 requests
  fail. Health monitors may or may not catch it depending on timing,
  which is why it looks random.

- With `externalTrafficPolicy: Cluster`, any node accepts the NodePort
  connection and kube-proxy forwards it to the NIC pod wherever it
  lives. All three pool members work. Source IP is SNAT'd, but BIG-IP
  has already replaced the client IP with its own self-IP, so `Local`
  preserved nothing useful anyway.

The lab sets `externalTrafficPolicy: Cluster` in
[`values/nginx-ingress.yaml`](../../values/nginx-ingress.yaml).

If you ever scale NIC to a DaemonSet or one replica per node, `Local`
becomes viable again — but `Cluster` is correct and simplest for the
default single-replica lab.

## Klipper vs the k3d serverlb (don't confuse them)

- **Klipper / k3s ServiceLB** (the `svclb-*` DaemonSet pods) is the
  built-in controller that hands `type: LoadBalancer` services an
  external IP. The lab **disables** it (`--disable=servicelb`) because
  BIG-IP is now the load balancer. With it gone, a `LoadBalancer`
  service would sit at `<pending>` forever — which is why NIC must be
  NodePort or ClusterIP.

- **k3d serverlb** (the `k3d-<cluster>-serverlb` Docker container) is
  k3d's host-port proxy. It is **not** removed and is still required:
  it is what makes `172.16.20.145:80/443/3008x` reachable from the
  host. `task test` and `task health` rely on it.

Removing Klipper does not touch the k3d serverlb.

## Host access after Klipper removal

`create-cluster.sh` proxies host `:80 -> NIC_HTTP_NODEPORT` and
host `:443 -> NIC_HTTPS_NODEPORT` through the k3d serverlb, so
`task test` / `task health` keep working on standard ports in
**NodePort mode**.

In **ClusterIP mode** there is no NodePort, so host `:80/:443` reach
nothing — BIG-IP (via the VTEP tunnel) is the only ingress path. This
is expected; `task test` against `LAB_HOST_IP` will not pass in
ClusterIP mode unless you point it at the BIG-IP VIP instead.

## References

- F5 CIS docs: https://clouddocs.f5.com/containers/latest/
- NGINX Ingress Helm parameters: https://docs.nginx.com/nginx-ingress-controller/installation/installing-nic/installation-with-helm/
- Cilium VTEP setup for ClusterIP mode: [`cni/cilium/README.md`](../../cni/cilium/README.md)
