# ADR 0004 — `apps:up` waits for pod readiness

**Status:** Accepted

**Date:** 2026-04

## Context

[`Taskfile.yaml`](../../Taskfile.yaml)'s `task up` pipeline ends with:

```yaml
- task: apps:up
- task: health
```

`apps:up` applies the Kustomize overlays for every app in `LAB_APPS`.
`health` runs [`scripts/health-check.sh`](../../scripts/health-check.sh),
which takes a point-in-time snapshot of cluster state and returns
non-zero if any pod isn't Ready.

Prior to this decision, `apps:up` returned immediately after
`kubectl apply`. On a cold-start `task reset`, the snapshot raced the
app cold-start. Observed result on measured timings:

- **crAPI identity** (Spring Boot, Postgres-backed): ~22 seconds from
  pod start to Ready, sometimes longer on a stressed VM.
- **crAPI web, workshop, community**: additional ~10-15 seconds each
  waiting on identity.
- **Juice Shop, DVGA, VAmPI**: 5-15 seconds each.

`task health` ran roughly 5 seconds after `apps:up` and consistently
caught apps mid-`ContainerCreating`, reported 4 failures, and returned
non-zero. User had to run `task health` manually 60 seconds later to
see the true Ready state. Exit code of `task up` was misleading.

## Decision

Make `apps:up` wait for every app namespace's pods to be Ready before
returning. Inside the task, after the `waf-off` step, iterate over
`LAB_APPS` and `kubectl wait --for=condition=ready pod --all` with
per-app timeouts:

```yaml
apps:up:
  cmds:
    - task: waf-off
    - |
      APPS=$(read_lab_apps_from_lab_env)
      for a in $APPS; do
        case "$a" in
          crapi)     NS=crapi;      TIMEOUT=180s ;;
          juiceshop) NS=juice-shop; TIMEOUT=120s ;;
          dvga)      NS=dvga;       TIMEOUT=120s ;;
          vampi)     NS=vampi;      TIMEOUT=120s ;;
        esac
        echo "Waiting for $NS pods to be Ready..."
        kubectl wait --for=condition=ready pod --all -n "$NS" --timeout="$TIMEOUT"
      done
    - echo "All selected apps are Ready"
```

Timeouts reflect measured cold-start times with 3x padding.

## Consequences

### Positive

- **`task up` exits 0 on success.** Reset is a clean one-shot.
- **Semantic cleanup.** `task apps:up` now actually means "apps are
  up," not "apps are scheduled." Any downstream workflow like
  `task apps:up && task scan` works on the next line.
- **Honors `LAB_APPS`.** Same parser as `apps:down`; a subset config
  doesn't wait on namespaces that don't exist.

### Negative / costs

- **Slightly longer `task up`.** On a warm cache with apps ready in
  5-10 seconds, the wait adds zero. On a cold start with slow identity,
  ~45-60 seconds of explicit waiting replaces the user's implicit
  60-second manual re-check. Net time is identical; the feedback is
  better.
- **Long timeouts on pathological failures.** If crAPI identity
  truly can't start (e.g. Postgres image pull fails), `kubectl wait`
  blocks for 180 seconds before failing. Mitigation: the wait output
  is live, so the user sees what's stuck and can Ctrl+C.

## Alternatives considered

- **Put the wait in `task up`, not `apps:up`.** Narrower blast
  radius, but leaves `apps:up` still returning prematurely if anyone
  called it outside the `up` pipeline. Consistency argues for placing
  the wait in `apps:up`.
- **Use Deployment-level wait** (`kubectl rollout status` or
  `--for=condition=available deployment --all`). Pod-level is stricter
  — catches init-container-blocked pods. Deployment-level can return
  early when one of multiple replicas is ready.
- **Skip the wait, document the race as a known issue.** User
  experience cost.

## Consequences for future apps

Adding a new app to `LAB_APPS` requires adding a case arm in the wait
loop with a timeout budget. Guideline: measure cold-start once, pad 3x.

## Related

- [architecture/waf-overlay-toggle.md](../architecture/waf-overlay-toggle.md) —
  the `apps:up` task also applies the default WAF-disabled overlay.
