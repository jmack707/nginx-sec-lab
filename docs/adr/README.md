# Architecture Decision Records

Short documents capturing design decisions that aren't obvious from the
code. The format follows [Michael Nygard's template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions):

- **Context** — the problem and constraints that drove the decision.
- **Decision** — what we chose.
- **Consequences** — what this now requires of contributors or users.

## Index

| # | Title | Status |
|---|---|---|
| [0001](./0001-podmonitor-over-chart-servicemonitor.md) | PodMonitor instead of chart-driven ServiceMonitor | Accepted |
| [0002](./0002-distinct-registry-paths-for-nic-modes.md) | Distinct registry paths for NIC OSS vs Plus | Accepted |
| [0003](./0003-pvc-omits-storage-class.md) | PVC omits `storageClassName` | Accepted |
| [0004](./0004-apps-up-waits-for-readiness.md) | `apps:up` waits for pod readiness | Accepted |

## Writing a new ADR

Copy one of the existing files, bump the number, update the index.

Guideline: if a future contributor might look at the decision and
think "this looks odd, let me simplify it," there should be an ADR
explaining why simplifying it is a bad idea.
