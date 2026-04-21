# Scenarios

Hands-on walkthroughs of vulnerabilities in the demo apps. Each scenario
follows the same template:

1. **Vulnerability class** — what it is in OWASP taxonomy terms.
2. **Setup** — prerequisites (users registered, tokens obtained).
3. **Baseline reproduction** — the exact curl that demonstrates the
   vulnerability, with the expected response body/status.
4. **Observability** — which Grafana panel to watch, what shape to look
   for in logs.
5. **Protected reproduction** — the same curl after `task waf-on`, with
   what changes. OSS users: see note below.
6. **Real-world correlate** — a published incident or CVE this pattern
   maps to.

## OSS vs Plus

In OSS mode, `task waf-on` applies the Kustomize overlay but does not
enforce — NGINX App Protect is a Plus-only feature. Steps 5 in each
scenario describes both behaviors:

- **Plus mode**: App Protect returns HTTP 403 with a support ID, and
  `task logs:waf` shows the matched signature.
- **OSS mode**: the attack still succeeds; the overlay toggle is for
  testing overlay mechanics, not enforcement. Use OSS to establish
  baseline behavior; use Plus to see the mitigation.

## Index

| # | Scenario | App | Difficulty | OWASP mapping |
|---|---|---|---|---|
| 01 | [BOLA — Access another user's vehicle](./01-crapi-bola.md) | crAPI | Easy | API1:2023 |
| 02 | [SQL injection in login](./02-vampi-sqli.md) | VAmPI | Easy | API8:2023 |
| 03 | [JWT weak-key forgery](./03-vampi-jwt-weak.md) | VAmPI | Medium | API2:2023 |
| 04 | [GraphQL introspection + query depth](./04-dvga-graphql-introspection.md) | DVGA | Easy | API9:2023 |
| 05 | [Mass assignment](./05-crapi-mass-assignment.md) | crAPI | Medium | API6:2023 |

## Running scenarios

Every scenario assumes the lab is up:

```bash
task up
task test       # confirm all endpoints reachable
```

Seed crAPI users before running any crAPI scenario:

```bash
task crapi:seed
```

Open Grafana in a browser before starting — every scenario references
specific panels:

```bash
task metrics    # http://localhost:3000 → Dashboards → NGINX Lab → OSS
```

Keep a second terminal open for log tails:

```bash
task logs:nginx     # NGINX access log — shows attack traffic succeeding (200s)
task logs:waf       # App Protect events (Plus mode only)
```

## Writing new scenarios

Copy one of the existing scenarios as a template. The curl commands
should be self-contained — no reliance on env vars set in other
terminals. If a scenario needs a JWT, include the full login flow
inline.

Keep each scenario short (one page rendered), and lean on the observability
section rather than long explanations: "the attack succeeded" is boring,
"here's what the 403 response and the App Protect support ID look like" is
useful.
