# RHCL National Parks API Gateway Demo

A hands-on **Red Hat Connectivity Link (RHCL) 1.4.3** demo on **OpenShift 4.22**. One small REST API shows API keys, API Products, rate limiting, and **JWT authentication with Keycloak**.

**Start here:** Run the commands below from the repository folder. The full test is read-only and reports **PASS / FAIL / SKIP**.

## 1. Deploy the API Gateway

Requirements: logged-in `oc`, `curl`, `jq`, RHCL/Kuadrant installed, and `openshift-default` GatewayClass.

```bash
oc whoami
oc get kuadrant -A
oc get gatewayclass openshift-default

oc apply -f rhcl-parks-demo.yaml
oc -n rhcl-parks-demo rollout status deployment/parks-api --timeout=180s
bash scripts/expose-route.sh
bash scripts/check-policies.sh
```

The API is served through **OpenShift HTTPS Route → Gateway → National Parks API**. The Route must point to `parks-gw-openshift-default`, **not** directly to the app (which would bypass security).

## 2. Publish the API Product and approve a key

```bash
oc apply -f docs/api-product.yaml
oc -n rhcl-parks-demo get apiproduct national-parks-api
```

Create the consumer namespace **if it does not already exist**: `oc create namespace rhcl-parks-consumer`.

In the OpenShift console:

1. **Connectivity Link API Catalog → My API Keys** (namespace `rhcl-parks-consumer`): request a key for **National Parks API**; use name `test-key`.
2. **API Key Approvals** (owner namespace `rhcl-parks-demo`): approve the request.
3. Return to **My API Keys** to view the approved key. Keep its value private.

Verify approval without displaying the key:

```bash
oc -n rhcl-parks-consumer get apikey test-key \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

Expected: `Approved=True`. If you already have the approved `test-key`, **reuse it**; no need to create another.

## 3. Enable JWT authentication with Keycloak

```bash
bash scripts/setup-jwt-demo.sh
oc -n rhcl-parks-demo rollout status deployment/parks-keycloak --timeout=300s
```

Open the `parks-keycloak` Route, sign in to the **parks** realm, and find **Clients → parks-demo-client → Credentials**. Copy the *client secret*, not the Keycloak admin password. The test runner prompts for it securely. The `client_credentials` token lifetime is **120 seconds**.

## 4. Run the full test

```bash
bash scripts/test-all.sh --quick
```

Or run the longer test, which also checks JWT expiration:

```bash
bash scripts/test-all.sh
```

The runner prompts for your **approved consumer API key** and **Keycloak client secret** if not supplied in the environment. It does **not print secrets** or change Kubernetes resources.

| Check | Expected result |
| --- | --- |
| Gateway, HTTPRoute and AuthPolicy | Accepted / Enforced |
| Valid API key, missing parameter/key, unknown park | **200 / 400 / 401 / 404** |
| API Product + approved consumer key | Published, Approved, **200** |
| Keycloak JWT | Valid **200**; absent/expired **401** |
| JWT rate limit | **429** after repeated authenticated calls |
| Latency smoke test | p50 / p95 / p99 (20 requests) |

**Last verified on this lab:** `25 PASS · 0 FAIL · 9 SKIP` using `--quick`. A SKIP means **not tested**, not passed.

## 5. What the rate limits mean

The current lab uses `parks-plans` (an enforced **PlanPolicy**) on `parks-api`:

| Plan | Configured daily quota |
| --- | ---: |
| Bronze | 100 requests |
| Silver | 500 requests |
| Gold | 1,000 requests |

This policy **intentionally overrides** the original `parks-rate-limits` (Alice/Bob burst and sustained rules). The script verifies the active plan configuration but **does not consume a full daily allowance to force 429**. Tier limits may be shared by multiple consumers; don't use these daily plans as proof of individual-client burst protection.

The **JWT route** `/jwt/ws/data/all` is separate and **does** demonstrate per-subject `429` using its own enforced RateLimitPolicy.

## 6. Quick troubleshooting

```bash
bash scripts/check-policies.sh
oc -n rhcl-parks-demo get planpolicy parks-plans
oc -n rhcl-parks-demo get authpolicy parks-auth parks-jwt-auth
oc -n rhcl-parks-consumer get apikey test-key
```

- **Approved API key returns 401:** The Developer Portal creates a **managed enforcement Secret** in `openshift-operators`, separate from the consumer's `test-key-secret`. It must have `app=parks-api` for Authorino's `matchLabels` selector. Check metadata only:
  ```bash
  oc -n openshift-operators get secret \
    -l devportal.kuadrant.io/apikey=test-key \
    --show-labels
  ```
  If an *existing* managed Secret lacks the label, repair that specific Secret's `app=parks-api` label; don't copy or print the consumer credential.
- **Original RateLimitPolicy says Overridden:** Expected while `parks-plans` is Enforced. Don't delete the PlanPolicy just to turn a test green.
- **JWT returns 401:** Obtain a fresh 120-second token; check the Keycloak **client** secret and service accounts.
- **Malformed JWT returns 504:** Known issue observed with the RHCL 1.4.3 gateway WASM shim in this lab. Not a successful security-negative test; collect logs and raise a support case.

## Scope and limitations

- **Lab-only TLS:** the runner uses `curl -k` for this cluster's untrusted certificate. Use `VERIFY_TLS=1` with trusted certificates.
- **Keycloak:** development mode, ephemeral storage; not a production HA configuration.
- **Not installed/tested:** OpenTelemetry trace backend, WAF, AWS Shield, and volumetric DDoS protection. RHCL authentication/rate limits **do not replace** upstream DDoS controls.
- The original Alice/Bob quotas and daily plan `429` are **SKIP** while the active PlanPolicy is used.

## Files

| File | Purpose |
| --- | --- |
| [rhcl-parks-demo.yaml](rhcl-parks-demo.yaml) | Sample API, Gateway and API-key policies |
| [docs/api-product.yaml](docs/api-product.yaml) | API Product |
| [scripts/setup-jwt-demo.sh](scripts/setup-jwt-demo.sh) | Keycloak and JWT setup |
| [scripts/test-all.sh](scripts/test-all.sh) | Full read-only test |
| [scripts/check-policies.sh](scripts/check-policies.sh) | Troubleshooting checks |

Reference: [RHCL 1.4 documentation](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4) · [PlanPolicy](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/rhcl-planpolicy)
