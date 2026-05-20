# Nuclei baseline measurements

Captured by `task scan:nuclei` (scripts/run-scan.sh nuclei).

## Naming

`<date>-<mode>-<waf-state>.{txt,json}`.

## Baseline (2026-05-20, OSS WAF-off)

- Templates loaded: 2540 (561 after clustering)
- Targets: 4 (crAPI, Juice Shop, DVGA, VAmPI)
- Duration: ~7 minutes
- Total findings: 60 (18 unique after deduping per-header rows)

### Severity breakdown

| Severity | Count | Notes |
|---|---|---|
| high | 3 | All `.env` probes on crAPI. Three different templates (codeigniter/laravel/generic) flag the same URL -- likely false positives since crAPI uses neither framework. NGINX returns generic content at `/.env` that matches multiple template regex patterns. |
| medium | 1 | Juice Shop `/metrics` endpoint exposed. By design for observability demos. |
| info | 56 | Missing security headers (13 templates × 4 apps = 52) + DVGA GraphQL detection (5) + VAmPI OpenAPI exposure (1) + Juice Shop Swagger (1) + DVGA cookies-without-secure/httponly + missing-cookie-samesite-strict. |

### Unique findings by template

| Severity | Template | Host | Match |
|---|---|---|---|
| high | codeigniter-env | crapi.lab.local | /.env |
| high | generic-env | crapi.lab.local | /.env |
| high | laravel-env | crapi.lab.local | /.env |
| medium | prometheus-metrics | juiceshop.lab.local | /metrics |
| info | cookies-without-httponly | dvga.lab.local | |
| info | cookies-without-secure | dvga.lab.local | |
| info | graphql-alias-batching | dvga.lab.local | /graphql |
| info | graphql-array-batching | dvga.lab.local | /graphql |
| info | graphql-detect | dvga.lab.local | /graphiql |
| info | graphql-field-suggestion | dvga.lab.local | /graphql |
| info | graphql-get-method | dvga.lab.local | /graphql?query={__typename} |
| info | http-missing-security-headers | (4 apps) | / |
| info | missing-cookie-samesite-strict | dvga.lab.local | |
| info | openapi | vampi.lab.local | /openapi.json |
| info | swagger-api | juiceshop.lab.local | /api-docs/swagger.json |

## Expected changes with WAF-on (Plus mode)

- `.env` findings: likely unchanged. WAF doesn't change behavior on
  dotfile paths unless explicitly configured to block them. Worth
  verifying separately whether crAPI's response at `/.env` is a 404
  or a SPA catch-all 200 (see hardening notes below).
- `/metrics` exposure: unchanged unless explicit policy added.
- GraphQL detection on DVGA: should drop. App Protect has signatures
  for introspection patterns; expect `graphql-detect`,
  `field-suggestion`, `alias-batching`, `array-batching`, and
  `get-method` to all clear.
- OpenAPI / Swagger spec exposure: should drop. App Protect blocks
  well-known spec disclosure paths.
- Missing security headers: unchanged. Header policy is NIC config
  via `add-headers` or `config-snippets`, not WAF behavior.

The strongest "before/after" comparison point will be the 5 DVGA
GraphQL findings. Expect them to drop to 0-1 under Plus.

## Hardening lessons surfaced by this baseline

1. **Add security headers via NIC `config-snippets`** to clear the
   52 missing-headers findings. Module 5 (NGINX hardening) territory.
2. **Block dotfile paths at NIC level**. Either via a global
   location rule or a `server-snippets` add. Eliminates the .env
   false positives whether they were real or not.
3. **OpenAPI / Swagger UI rate-limiting**. VAmPI and Juice Shop
   expose their specs by design, but in production these should be
   either disabled or rate-limited to authenticated requests.

## Re-run procedure

```bash
task waf-off                      # OSS baseline (this file)
task waf-on                       # Plus-enforced run
task scan:nuclei
```

Save the Plus-mode output as `<date>-plus-waf-on.{txt,json}` for
direct comparison.

## Quick analysis commands

```bash
# Severity counts
grep -oE '\[(critical|high|medium|low|info)\]' <file>.txt | sort | uniq -c

# Unique findings (one line per template/host pair)
jq -r '.[] | "\(.info.severity)\t\(.["template-id"])\t\(.host)\t\(.["matched-at"] // .host)"' \
  <file>.json | sort -u

# Diff two runs
jq -r '.[] | "\(.["template-id"])\t\(.host)"' baseline.json | sort -u > /tmp/baseline.txt
jq -r '.[] | "\(.["template-id"])\t\(.host)"' after.json | sort -u > /tmp/after.txt
diff /tmp/baseline.txt /tmp/after.txt
```
