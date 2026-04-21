# Cold-start recovery

When the lab is in an unknown or stuck state, work through these checks
in order. Each identifies a specific failure mode and the fix.

## Decision tree

```
Is the cluster up?
  kubectl get nodes  -->  "connection refused" / "no resources found"
                           → A. Cluster down
                      -->  "NotReady" nodes
                           → B. Node-level problem
                      -->  All Ready
                           → Proceed

Are all namespaces present?
  kubectl get ns  -->  missing nginx-ingress, crapi, etc.
                      → C. Pre-deploy incomplete
                 -->  All present
                      → Proceed

Are infra pods Ready?
  kubectl get pods -n nginx-ingress -n cert-manager -n monitoring
                 -->  ImagePullBackOff / ErrImagePull
                      → D. Image layer problem
                 -->  Pending with "unbound PVC"
                      → E. Storage problem
                 -->  CrashLoopBackOff
                      → F. App-specific failure
                 -->  All Running
                      → Proceed

Are endpoints reachable?
  task test  -->  All 502
                      → G. Network path problem
            -->  Some 502
                      → F. App-specific failure
            -->  All 200/401/405
                      → Lab is healthy
```

## A. Cluster down

```bash
docker ps | grep k3d-nginx-sec-lab
# Expect: 5 containers (server, 2 agents, serverlb, registry)
```

If some are missing:

```bash
k3d cluster list
# Shows cluster state

k3d cluster start nginx-sec-lab   # try to restart existing cluster

# If that fails, rebuild:
task reset
```

If `task reset` itself fails at cluster creation, check ports 80/443:

```bash
sudo ss -tlnp | grep -E ':80|:443 '
# Should show only k3d-proxy. Anything else (nginx, apache2, a dev server)
# blocks the k3d LoadBalancer from binding.
```

## B. Node-level problem

```bash
kubectl describe node <node-name> | tail -20
```

Common conditions:

- **`DiskPressure`** — VM disk is full. Resize in the hypervisor:
  ```bash
  sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2
  kubectl taint nodes --all node.kubernetes.io/disk-pressure-
  ```
- **`MemoryPressure`** — too many pods for VM size. Free memory by
  stopping unused apps: `LAB_APPS=crapi task apps:up` runs only crAPI.
- **`NotReady`** with no specific condition — k3s agent process is
  wedged. Restart the node container:
  ```bash
  docker restart k3d-nginx-sec-lab-agent-0
  ```

## C. Pre-deploy incomplete

```bash
# The namespaces that should exist after task pre-deploy
for ns in cert-manager nginx-ingress monitoring crapi juice-shop dvga vampi; do
  kubectl get ns $ns &>/dev/null && echo "OK $ns" || echo "MISSING $ns"
done
```

If any are missing:

```bash
bash scripts/pre-deploy.sh
```

This is idempotent — safe to run any time.

## D. Image layer problem

```bash
POD=$(kubectl get pods -A | grep -E 'ImagePull|ErrImage' | head -1 | awk '{print $2}')
NS=$(kubectl get pods -A | grep "$POD" | awk '{print $1}')
kubectl describe pod -n "$NS" "$POD" | grep -A5 "Events:"
```

Look at the Events section for the exact image name and error.

See [architecture/image-layers.md](../architecture/image-layers.md) for
the full three-tier model. Most common causes:

1. Registry mirror empty for this image → `task registry:cache`.
2. Registry has the wrong content (e.g. Plus binary at OSS tag):
   ```bash
   # Force re-push
   task registry:cache
   # Evict the cached image from k3d nodes
   for n in $(docker ps --format '{{.Names}}' | grep '^k3d-nginx-sec-lab-'); do
     docker exec "$n" crictl rmi <image>:<tag> 2>/dev/null || true
   done
   # Rollout so pods re-pull
   kubectl rollout restart deploy/<deployment> -n <ns>
   ```
3. Docker Hub rate limit hit → set `DOCKERHUB_USER` in `lab.env`, then
   `task registry:cache`.

## E. Storage problem

```bash
kubectl get pvc -A | grep -v Bound
# Shows only Pending PVCs
```

For each pending PVC:

```bash
kubectl describe pvc -n <ns> <pvc-name> | tail -10
```

Common outcomes:

- **`ProvisioningFailed: storageclass.storage.k8s.io "X" not found`** —
  PVC references a class that doesn't exist. Check
  `kubectl get sc`, then either annotate an existing class as default:
  ```bash
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  kubectl delete pvc -n <ns> <pvc-name>
  # Recreate: apply the Job manifest that uses it, or task locust/scan
  ```
- **`No storage class is available`** — k3d's local-path provisioner
  didn't install. Something went wrong with cluster creation; `task reset`.

## F. App-specific failure

```bash
# Get the logs
kubectl logs -n <ns> <pod> --previous 2>/dev/null || \
  kubectl logs -n <ns> <pod> --tail=50
```

Known app-specific issues:

### crAPI identity "Failed to connect to postgres"

Postgres still starting. crAPI identity retries for 60s. If it still
fails after 2 minutes:

```bash
kubectl get pods -n crapi -l app=crapi-postgres
kubectl logs -n crapi deploy/crapi-postgres --tail=30
```

### crAPI workshop returning 502

Service port mismatch. The lab's current version uses port 8000 (matches
gunicorn). If you see 8888 in the Service spec, you're on an old
version — update from git.

### Juice Shop "Something went wrong"

Free memory. Juice Shop is the heaviest app; in an 8GB VM with all four
apps running it can thrash.

### VAmPI returning 404 on `/users/v1/login`

Database not populated. VAmPI auto-creates its DB on startup, but if the
pod restarts during init it can lose the users. Restart:

```bash
kubectl rollout restart deploy/vampi -n vampi
```

## G. Network path problem

All four apps returning 502 is almost always a host-level iptables
issue, not a cluster issue.

```bash
# Is NIC reachable directly via ClusterIP?
NIC_IP=$(kubectl get svc -n nginx-ingress nginx-ingress-controller \
  -o jsonpath='{.spec.clusterIP}')
kubectl run -it --rm --image=curlimages/curl --restart=Never -n default curl-test -- \
  curl -sk -o /dev/null -w '%{http_code}' \
  --resolve "crapi.<domain>:80:${NIC_IP}" \
  "http://crapi.<domain>/"
```

If that returns 200 but external curl returns 502:

```bash
# Check for stale DNAT rules
sudo iptables -t nat -L PREROUTING -n --line-numbers | grep DNAT
# If any point at IPs/ports that aren't the current k3d-proxy, delete them:
sudo iptables -t nat -D PREROUTING <line-num>

# Re-run cluster setup to reinstall the correct DOCKER-USER rule
bash scripts/create-cluster.sh
```

The session most commonly hit this after switching VMs or changing
LAB_HOST_IP — old DNAT rules pointed at nothing, and every incoming
connection failed silently.

## Last resort

```bash
task down
docker stop k3d-registry.localhost && docker rm k3d-registry.localhost
task registry:setup
task registry:cache    # requires internet
task up
```

This rebuilds every layer. ~10 minutes on a fast VM. If this fails,
paste the failing step's output and the output of `task check` — the
issue is likely in prerequisites or the host's networking.
