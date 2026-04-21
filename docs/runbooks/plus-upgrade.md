# Plus mode upgrade

When your NGINX Plus JWT arrives, this is the checklist to move the
lab from OSS shadow mode to Plus with App Protect enforcement.

## Prerequisites

- **JWT from F5**. Get it at
  [my.f5.com](https://my.f5.com) → My Products → NGINX → Manage
  Subscriptions.
- **Network access** to `private-registry.nginx.com`.
- **Working OSS lab**. `task health` passes, apps are reachable. Don't
  try to upgrade a broken lab.

## Steps

### 1. Add the JWT to `lab.secrets` (NEVER to `lab.env`)

```bash
echo "NGINX_JWT=<paste-your-token-here>" >> lab.secrets
chmod 600 lab.secrets
```

`lab.secrets` is gitignored;
[`lab.env`](../../lab.env.example) is checked into git. Committing a
JWT is a real incident — double-check `.gitignore` covers `lab.secrets`
before the commit that changes anything else.

### 2. Flip `NGINX_MODE`

```bash
sed -i 's/^NGINX_MODE=oss/NGINX_MODE=plus/' lab.env

grep NGINX_MODE lab.env
# Expected: NGINX_MODE=plus
```

### 3. Re-cache images

```bash
task registry:cache
```

What happens:

- The script notices `NGINX_MODE=plus`, attempts `docker login` against
  `private-registry.nginx.com` using the JWT as the username.
- Pulls `private-registry.nginx.com/nginx-ic/nginx-plus-ingress:3.4.3`.
- Tags and pushes to the local mirror at a **distinct path** from the
  OSS image — both can coexist without collision.
- Other lab images aren't affected.

If the login fails, check the JWT for trailing whitespace or quotes.
The script logs the exact registry command on failure.

### 4. Update `values/nginx-ingress.yaml` for Plus

The current values file configures OSS. Plus mode needs three additions:

```yaml
controller:
  nginxplus: true              # enable Plus features in the binary
  appprotect:
    enable: true               # enable App Protect module
  image:
    repository: k3d-registry.localhost:5000/nginx-ic/nginx-plus-ingress
    tag: "3.4.3"
  # ... rest of the file as-is
```

Diff the change:

```bash
git diff values/nginx-ingress.yaml
```

### 5. Rebuild

```bash
task reset
```

This runs `task down` → `task up`. The full pipeline re-runs with
Plus-mode config.

### 6. Verify

```bash
# The binary line should now include 'nginx-plus-*'
kubectl logs -n nginx-ingress deploy/nginx-ingress-controller | \
  grep 'Using nginx version'
```

Expected:

```
Using nginx version: nginx/1.25.3 (nginx-plus-r31-p1)
```

The OSS version was `nginx/1.25.3` with no suffix — the presence of
`nginx-plus-rXX` is the confirmation.

```bash
# The App Protect CRDs should now be present and the policies applied
kubectl get appolicy,aplogconf -n nginx-ingress
```

Expected:

```
NAME                           AGE
appolicy.appprotect.f5.com/owasp-crs          1m
appolicy.appprotect.f5.com/dataguard-alarm    1m

NAME                           AGE
aplogconf.appprotect.f5.com/logconf-stdout    1m
```

`task health` no longer shows those entries as warnings.

### 7. Test enforcement

```bash
task waf-on
task scan         # GoTestWAF against crAPI
```

On Plus, the GoTestWAF report's "blocked" percentage should jump
dramatically compared to the OSS baseline — typical results are
85-95% blocked where OSS was 0%.

Check the Grafana Plus dashboard:

```bash
task metrics    # http://localhost:3000 → NGINX Security Lab — Plus
```

The *Responses by App and Code* panel should show a spike in `crapi 4xx`
during the scan, while the other apps stay quiet.

## Reverting to OSS

```bash
sed -i 's/^NGINX_MODE=plus/NGINX_MODE=oss/' lab.env

# Revert values/nginx-ingress.yaml (or just `git checkout`)
git checkout values/nginx-ingress.yaml

task reset
```

No need to re-cache images — OSS images are already in the local
registry from earlier runs. They live at a different path than Plus,
so the mode-switch doesn't touch them.

## Troubleshooting

### `docker login` to private-registry.nginx.com fails

- Verify JWT is current (F5 rotates these occasionally).
- Verify the JWT was pasted without surrounding quotes or newlines.
- Try the login manually to see the full error:
  ```bash
  docker login private-registry.nginx.com --username="$NGINX_JWT" --password=none
  ```

### NIC pod starts but `task health` says "NGINX Plus binary found without NGINX Plus flag"

Registry has a stale Plus image under the OSS tag, or vice versa. Fix:

```bash
task registry:cache    # force re-pushes the NIC image on every run
# Delete the cached image on each k3d node
for n in $(docker ps --format '{{.Names}}' | grep '^k3d-nginx-sec-lab-'); do
  docker exec "$n" crictl rmi docker.io/nginx/nginx-ingress:3.4.3 2>/dev/null || true
done
# Rollout restart so containers re-pull
kubectl rollout restart deploy/nginx-ingress-controller -n nginx-ingress
```

### App Protect policy fails to apply

`kubectl describe appolicy -n nginx-ingress owasp-crs` — look at the
`status` section. Common issues: invalid JSON in the policy body,
references to signature sets not included in the lab's image.

For deep debugging, check NIC logs during a pod start:

```bash
kubectl logs -n nginx-ingress deploy/nginx-ingress-controller -f | \
  grep -iE 'protect|policy|wafd'
```
