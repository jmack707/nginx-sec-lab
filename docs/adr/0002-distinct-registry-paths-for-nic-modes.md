# ADR 0002 — Distinct registry paths for NIC OSS vs Plus

**Status:** Accepted

**Date:** 2026-04

## Context

The lab supports both NGINX OSS (default, no license required) and
NGINX Plus (requires F5 JWT). A user switching between modes via
`NGINX_MODE=oss` / `NGINX_MODE=plus` and re-running `task registry:cache`
would previously re-tag whichever image they pulled to the same
destination path in the local registry:

```bash
# Original pull-and-cache.sh — same destination for both modes
if [ "$NGINX_MODE" = "plus" ]; then
  NGINX_IMAGE="private-registry.nginx.com/nginx-ic/nginx-plus-ingress:3.4.3"
else
  NGINX_IMAGE="nginx/nginx-ingress:3.4.3"
fi
NGINX_DST="nginx/nginx-ingress:3.4.3"   # ← same for both modes
```

This caused a subtle failure mode:

1. User runs `NGINX_MODE=plus task registry:cache`. Registry now has
   the Plus binary at `k3d-registry.localhost:5000/nginx/nginx-ingress:3.4.3`.
2. User switches to OSS for whatever reason (token expired, testing OSS
   behavior, lab reset).
3. User runs `task reset`. NIC image pulls from the local registry,
   which still serves the Plus binary.
4. NIC pod starts, detects it's the Plus binary, refuses to run with
   the OSS `-nginx-plus=false` flag. Crash-loops with:
   ```
   F0420 17:36:44.204646 1 main.go:412]
     NGINX Plus binary found without NGINX Plus flag (-nginx-plus)
   ```

The failure signal was several steps removed from the cause. A user
might blame the chart, the k3d config, their JWT, their network — and
not realize the registry was poisoned from a previous run.

## Decision

1. **Use distinct destination paths per mode** in
   [`scripts/pull-and-cache.sh`](../../scripts/pull-and-cache.sh):

   ```bash
   if [ "$NGINX_MODE" = "plus" ]; then
     NGINX_IMAGE="private-registry.nginx.com/nginx-ic/nginx-plus-ingress:3.4.3"
     NGINX_DST="nginx-ic/nginx-plus-ingress:3.4.3"   # distinct
   else
     NGINX_IMAGE="nginx/nginx-ingress:3.4.3"
     NGINX_DST="nginx/nginx-ingress:3.4.3"
   fi
   ```

2. **Always force-repush the NIC image** on every `task registry:cache`,
   bypassing the normal "skip if already cached" shortcut. The
   `cache()` helper takes an optional third arg (`force=1`); the NIC
   line passes it.

## Consequences

### Positive

- **Modes can coexist in the registry.** Both OSS and Plus binaries
  live at distinct paths; a switch doesn't overwrite anything.
- **Registry self-heals.** Even if a previous version of the script
  left a poisoned tag, the next `task registry:cache` run overwrites
  the NIC destination with the image corresponding to the current
  `NGINX_MODE`.
- **The `values/nginx-ingress.yaml` Plus override is clean.** Plus mode
  references `k3d-registry.localhost:5000/nginx-ic/nginx-plus-ingress:3.4.3`
  (a distinct path), OSS references `.../nginx/nginx-ingress:3.4.3`
  (the default the chart expects). No magic.

### Negative / costs

- **Slight registry bloat.** Both binaries sit in the local registry
  even if the user only runs one mode. ~200MB extra for the unused
  variant. Trivial on a 40GB lab VM.
- **Force-repush is slower.** Each `task registry:cache` re-runs the
  docker push for the NIC image even if the registry already has it.
  Docker layer dedup keeps this fast (~5 seconds for the small top
  layer).

### Requirements on users

- **Plus mode requires a values override.** The chart defaults to
  `nginx/nginx-ingress`. Plus users must set
  `controller.image.repository` in `values/nginx-ingress.yaml`.
  Documented in [runbooks/plus-upgrade.md](../runbooks/plus-upgrade.md).

## Alternatives considered

- **Share a destination, rely on discipline.** What we had. Doesn't
  survive the "user forgot which mode they're in" case.
- **Delete the registry on mode switch.** Heavy-handed; loses the
  ~20 other cached images that are unaffected by the mode.
- **Use tags instead of paths to distinguish (e.g. `3.4.3-plus` vs
  `3.4.3-oss`).** Would work, but then the chart's default
  `image.tag: "3.4.3"` doesn't match either — every mode needs a values
  override. Path-based distinction lets OSS use chart defaults.

## Related

- [architecture/image-layers.md](../architecture/image-layers.md) —
  how the three image supply tiers interact.
- [runbooks/plus-upgrade.md](../runbooks/plus-upgrade.md) — the full
  Plus-mode upgrade procedure.
