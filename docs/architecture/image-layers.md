# Image supply model

The lab has three layers that can serve any given container image. They
cascade — each tier falls back to the next. Understanding the tiers
explains why `task registry:cache` exists, why `task reset` works
offline, and what to do when an image pull fails.

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1 — Local registry mirror                             │
│   k3d-registry.localhost:5000  (Docker container)           │
│   Populated by: task registry:cache                         │
│   Survives:     task down, task reset                       │
│   Consulted via registries.yaml mirror config               │
└───────────────────────┬─────────────────────────────────────┘
                        │ missed?
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 2 — k3d image import                                  │
│   host Docker daemon → containerd on each k3d node          │
│   Populated by: task images:import (via task up)            │
│   Handles:      11 single-arch demo/app images              │
│   Survives:     task down NO (rebuilt on task up)           │
└───────────────────────┬─────────────────────────────────────┘
                        │ missed?
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 3 — Public internet                                   │
│   docker.io, quay.io, gcr.io, etc.                          │
│   Triggered:    containerd fallback                         │
│   Requires:     working DNS + egress                        │
└─────────────────────────────────────────────────────────────┘
```

## Layer 1 — Local registry mirror

A standalone Docker container (`k3d-registry.localhost`) running
`registry:2`, created once by
[`scripts/setup-registry.sh`](../../scripts/setup-registry.sh).

[`registries.yaml`](../../registries.yaml) tells k3s to use this
registry as a mirror for docker.io, quay.io, registry.k8s.io, and
ghcr.io. Any pull for those registries goes here first.

[`scripts/pull-and-cache.sh`](../../scripts/pull-and-cache.sh) pulls
the full lab image set (~20 images) and pushes them into the mirror.
Two design points:

- **NIC image is always force-repushed** — the script's `cache` helper
  takes an optional `force=1` flag; the NIC line uses it. This
  self-heals a "poisoned" registry where a previous `NGINX_MODE=plus`
  run left Plus content sitting under the OSS tag.
- **Plus and OSS use distinct destination paths.** Plus lands at
  `nginx-ic/nginx-plus-ingress:3.4.3`, OSS at `nginx/nginx-ingress:3.4.3`.
  A mode switch cannot overwrite the other mode's image.

See [ADR 0002](../adr/0002-distinct-registry-paths-for-nic-modes.md)
for the full reasoning.

## Layer 2 — k3d image import

[`scripts/import-images.sh`](../../scripts/import-images.sh) runs as
part of `task up` via `task images:import`. It enumerates a fixed
list of 11 single-arch images (crAPI services, Juice Shop, DVGA,
VAmPI, MongoDB, Postgres, MariaDB, MailHog) and — for each that's
already in the host's `docker images` cache — imports it into every
k3d node's containerd.

Why only 11? Multi-arch images (NIC, Grafana, cert-manager) don't
survive the `docker tag` + `docker push` + `k3d image import` round
trip — the manifest list gets flattened to a single arch, and on
mixed-arch nodes this causes pull failures. Layer 1 handles those
instead.

What happens when an image isn't in the host cache? The script prints
a warning and moves on. The cluster will resolve the image via Layer 1
or Layer 3 when pods schedule.

## Layer 3 — Public internet fallback

If Layer 1 and Layer 2 both miss, containerd falls through to the
public source referenced in the pod spec's `image:` field. Only
matters for cold-start VMs that haven't run `task registry:cache`.

Disabling this layer (for air-gapped labs) requires configuring
containerd to refuse unknown registries — not currently done, but
not hard to add.

## Decision tree: which command to use when

| Situation | Command | Why |
|---|---|---|
| First-ever setup on a new VM with internet | `task registry:setup && task registry:cache`, once | Populates Layer 1 so Layer 3 is never touched |
| Routine `task reset` | Nothing — `task up` handles imports | Layer 2 is auto-run, Layer 1 is preserved |
| `task reset` while offline | Nothing — `task up` handles imports | Everything from Layer 1 + Layer 2, no Layer 3 needed |
| Manually pulled a new image with `docker pull` | `task images:import` | Fastest — put it in Layer 2 without Layer 1 rebuild |
| Permanently adding a new image to the lab | Add to `pull-and-cache.sh`, run `task registry:cache` | Puts it in Layer 1 so it's always available |
| Image pull failing at pod schedule | See below | Diagnose which layer is missing |

## Diagnosing image-pull failures

```bash
# What's Kubernetes actually complaining about?
kubectl describe pod -n <ns> <pod> | tail -20
# Look for "ImagePullBackOff" or "ErrImagePull" with the image name.
```

Then check each layer for that image:

```bash
IMG="crapi/crapi-workshop:latest"   # or whatever failed

# Layer 1: is it in the registry mirror?
curl -s http://k3d-registry.localhost:5000/v2/_catalog | \
  python3 -m json.tool | grep -i "$(echo $IMG | cut -d: -f1)"

# Layer 2: is it in host Docker?
docker images --format '{{.Repository}}:{{.Tag}}' | grep "$IMG"

# Layer 2 landed in nodes?
for n in $(docker ps --format '{{.Names}}' | grep '^k3d-nginx-sec-lab-'); do
  echo "--- $n ---"
  docker exec "$n" crictl images 2>/dev/null | grep -i "$(echo $IMG | cut -d/ -f1)" | head -3
done
```

Common outcomes:

- **Layer 1 empty, Layer 2 empty, internet works** → run
  `task registry:cache`, then delete the stuck pod.
- **Layer 1 has it, Layer 2 empty, cluster can't pull** → registry
  mirror config isn't in effect. Check
  [`registries.yaml`](../../registries.yaml) is mounted on the nodes.
- **Layer 1 has the wrong content** (e.g. Plus binary under OSS tag) —
  re-run `task registry:cache` (NIC is always force-repushed; other
  images are re-pushed if the tag doesn't already exist).

## The "poisoned registry" failure mode

One of the session's more painful bugs. `pull-and-cache.sh` originally
re-tagged both `nginx/nginx-ingress:3.4.3` (OSS) and
`private-registry.nginx.com/nginx-ic/nginx-plus-ingress:3.4.3` (Plus)
to the same destination path in the local registry. If you ran the
script with `NGINX_MODE=plus` and later switched to `NGINX_MODE=oss`,
the Plus binary kept serving under the OSS tag. The NIC pod would
start, detect it was running the Plus binary without the `-nginx-plus`
flag, and fatally refuse to start:

```
F0420 17:36:44.204646 1 main.go:412]
  NGINX Plus binary found without NGINX Plus flag (-nginx-plus)
```

Current `pull-and-cache.sh` fixes this two ways:

1. **Distinct destination paths** per mode (`nginx/nginx-ingress:3.4.3`
   vs `nginx-ic/nginx-plus-ingress:3.4.3`). Modes can coexist in the
   registry without collision.
2. **Force re-push of the NIC image** on every `task registry:cache`.
   Even if the registry is somehow in an inconsistent state, the next
   cache run overwrites the NIC tag with the image corresponding to
   the current `NGINX_MODE`.
