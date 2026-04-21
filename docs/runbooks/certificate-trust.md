# Certificate trust

The lab uses a local certificate authority (CA) to sign TLS certs for
every app. Every machine that will hit the lab endpoints via a browser
or a curl without `-k` needs the CA installed in its trust store.

## What cert, where?

The CA is created by `task ca:init` on first `task up` and lives in the
repo root as:

- `root_ca.crt` — the public cert (safe to copy around)
- `root_ca.key` — the private key (**never share**; gitignored)

The `.crt` is what goes into client trust stores. The `.key` stays on
the lab host — it's used by cert-manager (imported via `task ca:import`)
to sign per-app TLS certificates.

## Getting the cert to your client

```bash
# From the lab host, copy to wherever your client is
scp root_ca.crt user@client-machine:/tmp/nginx-sec-lab-ca.crt
```

Or host it temporarily over HTTP:

```bash
# On the lab host
python3 -m http.server 8888 &
# On the client
curl -o /tmp/nginx-sec-lab-ca.crt http://<lab-ip>:8888/root_ca.crt
```

## Install — per platform

### Linux (Debian/Ubuntu)

```bash
sudo cp /tmp/nginx-sec-lab-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
# Expect: "1 added, 0 removed; done."
```

Verify:

```bash
openssl verify -CApath /etc/ssl/certs /usr/local/share/ca-certificates/nginx-sec-lab-ca.crt
# Expect: "OK"
```

Also update your shell:

```bash
echo '<LAB_HOST_IP>  crapi.<LAB_DOMAIN> juiceshop.<LAB_DOMAIN> dvga.<LAB_DOMAIN> vampi.<LAB_DOMAIN>' \
  | sudo tee -a /etc/hosts
```

Then `curl https://crapi.<LAB_DOMAIN>/` should work with no `-k`.

### Linux (RHEL/CentOS/Fedora)

```bash
sudo cp /tmp/nginx-sec-lab-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

### macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  /tmp/nginx-sec-lab-ca.crt
```

Prompts for the admin password twice (once for sudo, once for the
keychain). Safari and Chrome pick up the change immediately; Firefox
uses its own trust store (see below).

### Windows (PowerShell, as Administrator)

```powershell
Import-Certificate -FilePath C:\Users\<you>\Downloads\root_ca.crt `
  -CertStoreLocation Cert:\LocalMachine\Root
```

Or via GUI: double-click the .crt, "Install Certificate", "Local
Machine", "Place all certificates in the following store", select
"Trusted Root Certification Authorities".

Edge and Chrome use the system store; Firefox has its own.

### Firefox (all platforms)

Firefox doesn't use the OS trust store. Each profile needs the cert
imported manually:

1. Navigate to `about:preferences#privacy`.
2. Scroll to "Certificates" → "View Certificates…".
3. "Authorities" tab → "Import…".
4. Pick `root_ca.crt`, tick "Trust this CA to identify websites".

## Per-language runtimes

Some language runtimes maintain their own CA bundles, distinct from the
OS trust store. If you're writing scripts or tests against the lab:

### Python — `requests` / `httpx`

```bash
# Easiest: point REQUESTS_CA_BUNDLE at the cert
export REQUESTS_CA_BUNDLE=/path/to/root_ca.crt
python3 -c "import requests; print(requests.get('https://crapi.lab.local/').status_code)"
```

Or in code: `requests.get(url, verify='/path/to/root_ca.crt')`.

### Node.js

```bash
export NODE_EXTRA_CA_CERTS=/path/to/root_ca.crt
node script.js
```

### Go

Go uses the OS trust store by default on macOS/Windows. On Linux it
uses `/etc/ssl/certs/ca-certificates.crt`, which is updated by
`update-ca-certificates` — so if you followed the Linux section above,
Go programs work automatically.

### curl

System trust store. If `curl` from the host works, the cert is trusted.
In scripts you can also specify explicitly: `curl --cacert root_ca.crt`.

## Trust for the lab's built-in scans

The GoTestWAF, Nuclei, and Locust Jobs all use `-k` / `verify=False`
because they run inside the cluster and don't need CA verification to
test the ingress. No config needed for scanner trust.

## Rotating the CA

The default CA is valid 10 years. If you ever need to rotate:

```bash
# Backup the old CA in case anything still trusts it
mv root_ca.crt root_ca.crt.old
mv root_ca.key root_ca.key.old

# Generate a new one
task ca:init

# Push it into the cluster
task ca:import

# Re-issue all app certs
kubectl delete certificate --all -A
# cert-manager automatically re-issues them signed by the new CA
```

Every client trust store needs the new cert added. Old cert can stay
trusted until all clients are migrated — overlapping trust is fine.

## Un-trusting the lab CA

When you're done with the lab:

### Linux

```bash
sudo rm /usr/local/share/ca-certificates/nginx-sec-lab-ca.crt
sudo update-ca-certificates --fresh
```

### macOS

```bash
sudo security delete-certificate -c "nginx-sec-lab Root CA" /Library/Keychains/System.keychain
```

### Windows

`Cert:\LocalMachine\Root` → find "nginx-sec-lab Root CA" → delete.

### Firefox

`about:preferences#privacy` → Certificates → View Certificates →
Authorities tab → find "nginx-sec-lab Root CA" → Delete or Distrust.
