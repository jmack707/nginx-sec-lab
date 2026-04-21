# ADR 0003 — PVC omits `storageClassName`

**Status:** Accepted

**Date:** 2026-04

## Context

Several lab Jobs (GoTestWAF, Nuclei, Locust) write their reports to a
shared PVC defined in
[`jobs/results-pvc.yaml`](../../jobs/results-pvc.yaml). The original
manifest hard-coded the storage class:

```yaml
spec:
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
```

`standard` is a convention on GKE but **not a thing on k3d**. k3d ships
with the `local-path` provisioner as the default StorageClass; there is
no class named `standard`.

Failure mode observed: on a fresh `task locust` run, the PVC stayed
Pending with:

```
ProvisioningFailed: storageclass.storage.k8s.io "standard" not found
```

The Locust Job's pod stayed Pending with `unbound immediate
PersistentVolumeClaims`. No obvious way to tell from the pod error that
the real issue was a missing class name.

An explicit `storageClassName` in the PVC spec **overrides** the
cluster's default StorageClass annotation. Setting
`is-default-class=true` on `local-path` doesn't help when the PVC
asks for a specific different class by name.

## Decision

**Omit `storageClassName` entirely** from the PVC manifest. When the
field is absent, Kubernetes uses whatever StorageClass carries the
`storageclass.kubernetes.io/is-default-class: "true"` annotation.

```yaml
# jobs/results-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: scan-results-pvc
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  # storageClassName intentionally omitted — defer to cluster default
```

## Consequences

### Positive

- **Portable across clusters.** k3d → `local-path`. GKE → `standard-rwo`.
  EKS → `gp2` / `gp3`. AKS → `managed-csi`. No per-cluster patching.
- **Self-documenting.** A comment explicitly calling out that the
  omission is intentional (not a bug, not missed).
- **No re-configuration on `task reset`.** Every supported lab target
  provides a default StorageClass out of the box.

### Negative / costs

- **Assumes a default StorageClass exists.** On an unusual cluster
  where none is annotated default, the PVC stays Pending. The
  [cold-start-recovery runbook](../runbooks/cold-start-recovery.md)
  section E covers this — one kubectl patch fixes it.
- **Can't pin performance characteristics.** If a user wanted e.g. SSD
  storage specifically, they'd need to re-add `storageClassName`. Lab
  workloads don't need this.

## Alternatives considered

- **Hard-code `local-path`.** Works on k3d, breaks on GKE/EKS. Given
  the Taskfile + helmfile pattern, the lab could conceivably run on
  non-k3d clusters; hard-coding is unnecessarily restrictive.
- **Parameterize via `lab.env`.** `STORAGE_CLASS=local-path` plus a
  templating step. Overengineered for one field that defaulting solves.
- **Ship a custom StorageClass manifest.** Adds complexity for zero
  gain on k3d, which already has one.

## Related

- [runbooks/cold-start-recovery.md](../runbooks/cold-start-recovery.md) —
  section E covers the "Pending PVC" diagnostic flow.
- [scripts/run-scan.sh](../../scripts/run-scan.sh) — consumes this PVC.
- [scripts/run-locust.sh](../../scripts/run-locust.sh) — consumes this PVC.
