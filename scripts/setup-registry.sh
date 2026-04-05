#!/usr/bin/env bash
# scripts/setup-registry.sh
# Creates a local k3d registry and configures Docker to allow HTTP access.
# Run once per host. The registry survives task down / task up.
set -euo pipefail

REGISTRY_NAME="k3d-registry.localhost"
REGISTRY_PORT="5000"

echo "Setting up local k3d registry..."

# Create registry if not already running
if k3d registry list 2>/dev/null | grep -q "${REGISTRY_NAME}"; then
  echo "Registry '${REGISTRY_NAME}' already exists -- skipping creation"
else
  k3d registry create registry.localhost --port "${REGISTRY_PORT}"
  echo "Registry created: ${REGISTRY_NAME}:${REGISTRY_PORT}"
fi

# Configure Docker daemon to allow HTTP access to local registry
if docker info 2>/dev/null | grep -q "k3d-registry.localhost"; then
  echo "Docker insecure registry already configured -- skipping"
else
  echo "Configuring Docker to allow insecure registry access..."
  DAEMON_JSON="/etc/docker/daemon.json"

  if [ -f "$DAEMON_JSON" ]; then
    # Merge with existing config
    python3 << PYEOF
import json, sys
try:
    with open('${DAEMON_JSON}') as f:
        config = json.load(f)
except:
    config = {}
regs = config.get('insecure-registries', [])
entry = '${REGISTRY_NAME}:${REGISTRY_PORT}'
if entry not in regs:
    regs.append(entry)
    config['insecure-registries'] = regs
    with open('${DAEMON_JSON}', 'w') as f:
        json.dump(config, f, indent=2)
    print(f'  Added {entry} to {DAEMON_JSON}')
else:
    print(f'  {entry} already in {DAEMON_JSON}')
PYEOF
  else
    echo "  Creating ${DAEMON_JSON}..."
    echo "{\"insecure-registries\":[\"${REGISTRY_NAME}:${REGISTRY_PORT}\"]}" \
      > "${DAEMON_JSON}"
  fi

  echo "  Restarting Docker daemon..."
  systemctl restart docker
  sleep 3
  echo "  Docker restarted"
fi

echo ""
echo "Registry: ${REGISTRY_NAME}:${REGISTRY_PORT}"
echo "Status:   $(docker inspect --format='{{.State.Status}}' ${REGISTRY_NAME} 2>/dev/null || echo 'unknown')"
echo ""
echo "Next: task registry:cache   -- pull and cache all lab images"
