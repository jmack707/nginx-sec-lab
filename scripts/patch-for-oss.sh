#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# patch-for-oss.sh — Fix all known issues for NGINX OSS on kind
# Run ONCE before 'task up', or any time after 'task down'
# ──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Patching values/nginx-ingress.yaml — add hostNetwork for kind port mapping"
if ! grep -q 'hostNetwork' values/nginx-ingress.yaml; then
  sed -i '/^controller:/a\  hostNetwork: true\n  dnsPolicy: ClusterFirstWithHostNet' values/nginx-ingress.yaml
fi

echo "▸ Patching base/crapi/deployment-workshop.yaml — add MongoDB credentials"
if ! grep -q 'MONGO_DB_USER' base/crapi/deployment-workshop.yaml; then
  sed -i '/MONGO_DB_HOST/i\            - name: MONGO_DB_USER\n              value: "admin"\n            - name: MONGO_DB_PASSWORD\n              value: "crapisecretpassword"' base/crapi/deployment-workshop.yaml
fi

echo "▸ Patching base/vapi/deployment.yaml — TCP readiness probe instead of HTTP /vapi"
python3 - << 'PYEOF'
import re, sys
f = "base/vapi/deployment.yaml"
txt = open(f).read()
old = re.search(r'readinessProbe:\s*\n\s*httpGet:\s*\n\s*path: /vapi\s*\n\s*port: 80\s*\n\s*initialDelaySeconds: \d+\s*\n\s*periodSeconds: \d+', txt)
if old:
    txt = txt.replace(old.group(), """readinessProbe:
            tcpSocket:
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 10""")
    open(f, 'w').write(txt)
    print("  ✓ vapi readiness probe patched")
else:
    print("  – vapi readiness probe already patched or not found")
PYEOF

echo "▸ Patching Taskfile.yaml — make AP policies optional in issuer task"
if grep -q 'ap-logconf.yaml' Taskfile.yaml && ! grep -q 'ignore_error' Taskfile.yaml; then
  sed -i 's|kubectl apply -f policies/ap-logconf.yaml|kubectl apply -f policies/ap-logconf.yaml 2>/dev/null \|\| echo "  SKIP: App Protect CRDs not installed (NGINX Plus required)"|' Taskfile.yaml
  sed -i 's|kubectl apply -f policies/ap-policy-owasp.yaml|kubectl apply -f policies/ap-policy-owasp.yaml 2>/dev/null \|\| true|' Taskfile.yaml
  sed -i 's|kubectl apply -f policies/ap-policy-dataguard.yaml|kubectl apply -f policies/ap-policy-dataguard.yaml 2>/dev/null \|\| true|' Taskfile.yaml
fi

echo "▸ Creating pre-deploy script for resources needed before helmfile sync"
cat > scripts/pre-deploy.sh << 'PRE_EOF'
#!/usr/bin/env bash
# Create resources that helm charts depend on but don't create themselves
set -euo pipefail

echo "  Creating monitoring namespace and Grafana dashboard configmap..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap nginx-lab-dashboard \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  Creating nginx-ingress namespace and default TLS secret..."
kubectl create namespace nginx-ingress --dry-run=client -o yaml | kubectl apply -f -
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/nginx-default.key \
  -out /tmp/nginx-default.crt \
  -subj "/CN=nginx-default/O=nginx-sec-lab" 2>/dev/null
kubectl create secret tls default-server-secret \
  --cert=/tmp/nginx-default.crt \
  --key=/tmp/nginx-default.key \
  --namespace nginx-ingress \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/nginx-default.key /tmp/nginx-default.crt

echo "  Pre-deploy resources ready."
PRE_EOF
chmod +x scripts/pre-deploy.sh

echo "▸ Patching Taskfile.yaml — add pre-deploy step before helmfile sync"
if ! grep -q 'pre-deploy' Taskfile.yaml; then
  sed -i '/- task: ca:import/a\      - task: pre-deploy' Taskfile.yaml
  # Add the pre-deploy task definition before the deploy task
  sed -i '/^  deploy:/i\  pre-deploy:\n    desc: "Create resources needed before helmfile sync"\n    cmds:\n      - bash scripts/pre-deploy.sh\n' Taskfile.yaml
fi

echo "▸ Adding /etc/hosts entries"
if ! grep -q 'juiceshop.lab.local' /etc/hosts; then
  echo "  Need sudo to update /etc/hosts"
  echo "127.0.0.1 juiceshop.lab.local dvga.lab.local vapi.lab.local crapi.lab.local" | sudo tee -a /etc/hosts
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  All patches applied."
echo "  Run:  task down && task up"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
