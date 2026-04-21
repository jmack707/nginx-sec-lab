# WAF overlay toggle

## The pattern

Each demo app has a [`base/`](../../base/) Kustomize directory with its
Deployment, Service, Ingress, Certificate, and kustomization.yaml.
[`overlays/<app>/`](../../overlays/) contains two siblings:

```
overlays/
└── crapi/
    ├── waf-disabled/
    │   └── kustomization.yaml    # references base/, no patches
    └── waf-enabled/
        └── kustomization.yaml    # references base/, patches the Ingress
                                    # with App Protect annotations
```

The toggle is literally which directory gets applied:

```bash
kubectl apply -k overlays/crapi/waf-disabled   # task waf-off
kubectl apply -k overlays/crapi/waf-enabled    # task waf-on
```

[`scripts/apps-waf.sh`](../../scripts/apps-waf.sh) wraps both, reading
the `LAB_APPS` env var to iterate over the selected apps.

## What the "enabled" overlay actually does

[`overlays/crapi/waf-enabled/kustomization.yaml`](../../overlays/crapi/waf-enabled/kustomization.yaml):

```yaml
patches:
  - patch: |-
      - op: add
        path: /metadata/annotations/nginx.org~1app-protect-enable
        value: "True"
      - op: add
        path: /metadata/annotations/nginx.org~1app-protect-policy-name
        value: /nginx-ingress/owasp-crs
      - op: add
        path: /metadata/annotations/nginx.org~1app-protect-security-log-enable
        value: "True"
      - op: add
        path: /metadata/annotations/nginx.org~1app-protect-security-log
        value: /nginx-ingress/logconf-stdout
    target:
      kind: Ingress
      name: crapi
```

Four Ingress annotations. That's it. No Deployment changes, no Service
changes — pure NIC-consumed config.

The annotations reference two objects that live in the `nginx-ingress`
namespace:

- `/nginx-ingress/owasp-crs` → an `APPolicy` CR from
  [`policies/ap-policy-owasp.yaml`](../../policies/ap-policy-owasp.yaml)
- `/nginx-ingress/logconf-stdout` → an `APLogConf` CR from
  [`policies/ap-logconf.yaml`](../../policies/ap-logconf.yaml)

These are applied by [`task issuer`](../../Taskfile.yaml) (part of
`task up`). On OSS, the CRDs don't exist, the apply is tolerated with
`|| echo "SKIP: APPolicy not available"`, and `task waf-on` has no
enforcement effect.

## Why Kustomize overlays, not Helm values or raw patches?

**vs Helm values:**  a monolithic `appEnableWaf: true` value at the
Helm level would require re-rendering three charts and a rollout of the
NIC pod. Overlay-level patching lets us toggle per-app, instantly, with
no downtime. `kubectl apply -k` is atomic at the Ingress-annotation
level.

**vs a `kubectl patch` script:** overlays are declarative. The final
desired state of the Ingress lives in git. A script that `kubectl
patch`es at runtime is imperative and leaves the cluster in a state
that doesn't match any file in the repo. Kustomize also handles the
"multiple apps" case naturally — the `apps-waf.sh` loop just swaps
which overlay it applies per app.

## LAB_APPS — subset selection

[`lab.env`](../../lab.env.example) supports narrowing the active app
set:

```bash
LAB_APPS=crapi vampi          # only two apps active
```

[`apps-waf.sh`](../../scripts/apps-waf.sh) reads this and only applies
overlays to selected apps. `apps:up` and `apps:down` use the same
parser. Omitting `LAB_APPS` or leaving it blank defaults to all four.

Internal key-to-namespace mapping (only special case):
`juiceshop` → `juice-shop` (Kustomize directories use `juiceshop`,
Kubernetes namespaces use `juice-shop` because dashes are required in
most K8s object names). Everything else (`crapi`, `dvga`, `vampi`) maps
1:1.

## What the toggle does *not* do

- **Does not change the app.** No Deployment or Service is modified.
  The app's vulnerable behavior is identical with WAF on or off. The
  WAF blocks *requests that would have exploited* the vulnerability;
  the vulnerability remains in the application code.
- **Does not restart pods.** Annotations on Ingress trigger an NIC
  config reload (fast, no data plane interruption), not a pod
  restart.
- **Does not affect other apps.** Each overlay is namespaced; toggling
  crAPI's WAF doesn't touch Juice Shop.
- **Does not persist across `task apps:down`.** That deletes the
  namespace, which takes the Ingress with it. `task apps:up` re-applies
  the disabled overlay.

## Adding a new app to the toggle

1. Create `base/<newapp>/` with Deployment, Service, Ingress,
   Certificate, kustomization.yaml (mirror an existing app).
2. Create `overlays/<newapp>/waf-disabled/kustomization.yaml` —
   one-liner pointing at `../../../base/<newapp>`.
3. Create `overlays/<newapp>/waf-enabled/kustomization.yaml` with the
   App Protect annotation patch (copy from crAPI's).
4. Add `newapp` to the default list in
   [`scripts/apps-waf.sh`](../../scripts/apps-waf.sh) (look for the
   `APPS=` initialization).
5. Add it to
   [`scripts/health-check.sh`](../../scripts/health-check.sh) if you
   want it in the `task health` output.

Nothing else. The Taskfile's `waf-on` / `waf-off` tasks will pick it up
automatically via `LAB_APPS`.
