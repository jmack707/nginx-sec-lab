# cni/flannel — Placeholder

Flannel CNI support is planned for a future iteration.

## When to use Flannel over Cilium

- BIG-IP VXLAN tunnel with `flooding-type: none` (not multipoint)
- BIG-IP fake-node registration pattern (`bigip-node.yaml`)
- Matching an existing production cluster CNI
- Simpler L3 networking without eBPF overhead

## Planned files

- `kube-flannel.yaml` — Flannel DaemonSet manifest
- `bigip-node.yaml` — BIG-IP fake Kubernetes node for Flannel VTEP
- `values-cis-flannel.yaml` — CIS Helm values for Flannel ClusterIP mode
- `README.md` — Step-by-step setup guide

## Key difference from Cilium

With Flannel, BIG-IP must be registered as a fake Kubernetes node
(with the tunnel MAC in Flannel annotations) so the Flannel subnet
manager allocates a podCIDR for BIG-IP. Cilium uses VTEP config
instead and does not require the fake-node approach.
