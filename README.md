# RHCL National Parks API Gateway Demo

One copy/paste lab for **Red Hat Connectivity Link (RHCL) 1.4.3** on **OpenShift 4.22.18**. It exposes a small Parks-themed REST API through an **OpenShift HTTPS Route**, then demonstrates API-key authentication, HTTP status codes, per-client rate limits, API Products/API Keys, and JWT validation using Red Hat build of Keycloak.

This is the **only README**. Run commands from the repository root unless stated otherwise. The app is a self-contained Python REST API with four Australian parks, **not** the original Parksmap UI/MongoDB application.

**macOS/zsh tip:** Before pasting multi-line examples, run `setopt interactivecomments` so shell comment lines beginning `#` do not produce `zsh: command not found: #`. Use `read -rs VARIABLE` for hidden input on macOS; **do not use Bash's `read -p`** with zsh.

**If you cloned this repo before the documentation update:** Check `git status --short` first. If you have no local changes, refresh your clone once with `git fetch origin` followed by `git merge --ff-only origin/main`. Keep any personal changes rather than overwriting them. The GitHub README may be newer than your Mac's local copy.

## Run the complete test automatically

After deployment (Sections 1–2), start here instead of pasting every `curl` command:

```bash
bash scripts/test-all.sh
```

The runner is **read-only for Kubernetes resources**: it checks Gateway/HTTPRoute and policy status, exercises HTTP `200/400/401/404/429`, checks API Product publication and APIKey approval, requests a Keycloak JWT, checks JWT `200/401/429` and expiry, and measures latency with **20 harmless requests**. It prompts (with hidden input) for an **approved consumer API key** and the current **Keycloak client secret** when needed. It **never prints tokens or secrets**.

- **Full run (~3–4 minutes):** `bash scripts/test-all.sh` — includes 65-second rate-counter reset and up to 125-second JWT-expiry check.
- **Fast retest:** `bash scripts/test-all.sh --quick` — skips the sustained-window and token-expiry waits.
- **Noninteractive diagnostics:** `bash scripts/test-all.sh --quick --non-interactive` — skips credential-dependent tests unless the approved key/client secret have already been supplied by environment variables.
- **Skip latency probes:** add `--no-perf`.
- **TLS:** the default uses `curl -k` for this lab's untrusted Route certificate. Use `VERIFY_TLS=1 bash scripts/test-all.sh` when your certificates are trusted.

It prints one **PASS / FAIL / SKIP** line per check and a final count; exits nonzero when checks fail. **SKIP is not a PASS.** Importantly, if `parks-plans` overrides `parks-rate-limits`, it reports the policy issue and **skips** the original Alice/Bob quota tests; it **does not delete or change `parks-plans`**. Read Section 4 if you want to test those quotas.

**External WAF/DDoS and actual OpenTelemetry trace correlation** are explicitly `SKIP` because the repository doesn't provision these integrations. The known malformed-JWT `504` test is deliberately omitted.

## Tick-the-box demo checklist

- [ ] **Gateway:** Route → Gateway → Parks API; Gateway `Programmed=True`.
- [ ] **Policies:** `parks-auth` shows `Accepted=True` and `Enforced=True`; `parks-rate-limits` is enforced **only when not overridden by a PlanPolicy**.
- [ ] **HTTP status:** `200` valid key, `400` missing parameter, `401` missing key, `404` unknown park.
- [ ] **Burst:** Bob `429` after 2 requests/10s; Alice `429` after 5 requests/10s.
- [ ] **Sustained:** Alice `429` on the 16th request in a minute.
- [ ] **API Product/Keys (Tech Preview):** Publish product → request key → confirm `APPROVED` → read key in zsh → call API.
- [ ] **Keycloak:** OAuth2 client-credentials flow issues a 120-second signed JWT.
- [ ] **JWT:** Valid token `200`, missing/expired token `401`; JWT policies `Accepted=True`/`Enforced=True`.
- [ ] **JWT rate limits:** More than 5 calls/10s per authenticated subject → `429`.
- [ ] **Performance (optional):** Capture route p50/p95/p99 and throughput.
- [ ] **Tracing (optional):** Configure collector/back end separately and inspect spans.
- [ ] **WAF/DDoS (optional):** Validate an external WAF test rule and prevent bypass.

**Important:** This repo deploys the gateway policies and (optionally) disposable lab Keycloak. It does **not** install a tracing stack, WAF, AWS Shield, or volumetric DDoS protection.

## 1. Check OpenShift and RHCL prerequisites

Requirements: logged-in `oc`, `curl`, permissions to create lab namespace/routing/policies. Optional JWT setup needs `openssl`, `sed`, `jq` and Red Hat registry image access. **The optional PlanPolicy backup in Section 4 also requires `jq`**. Token decoding commands below use macOS `base64 -D`.

```bash
oc whoami
oc get clusterversion
oc -n openshift-operators get csv
oc get gatewayclass openshift-default
oc get kuadrant -A
oc get authorino,limitador -A
```

For the verified environment, `rhcl-operator.v1.4.3` and related CSVs are `Succeeded`, `openshift-default` GatewayClass is `Accepted=True`, and a **Ready Kuadrant instance** has Authorino and Limitador components. **Installing the RHCL Operator is not sufficient on its own.**

If `openshift-default` does not exist, a cluster administrator can create the native class:

```bash
oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF
```

If `oc get kuadrant -A` returns **No resources found**, first locate the Kuadrant Operator:

```bash
oc get deployments -A | grep kuadrant-operator-controller-manager
```

On this lab cluster its namespace is `openshift-operators` (replace the namespace below if yours differs). You can also use **Ecosystem → Installed Operators → Red Hat Connectivity Link → Kuadrant → Create Kuadrant**.

```bash
oc -n openshift-operators apply -f - <<'EOF'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
spec: {}
EOF

oc -n openshift-operators wait kuadrant/kuadrant \
  --for=condition=Ready=True --timeout=300s
```

**Reuse an existing healthy Kuadrant instance.** If policies still report `MissingDependency` *after* Kuadrant and GatewayClass are ready, check the Operator deployment and consider a controller restart, accounting for other consumers:

```bash
oc -n openshift-operators rollout restart deployment/kuadrant-operator-controller-manager
oc -n openshift-operators rollout status deployment/kuadrant-operator-controller-manager --timeout=180s
```

## 2. Install Parks and expose the HTTPS Route

If this is a fresh machine:

```bash
git clone https://github.com/waynedovey/rhcl-parks-api-gateway-demo.git
cd rhcl-parks-api-gateway-demo
```

If you are already inside the repository, start at `oc apply`:

```bash
oc apply -f rhcl-parks-demo.yaml
oc -n rhcl-parks-demo rollout status deployment/parks-api --timeout=180s
oc -n rhcl-parks-demo get gateway,httproute,pods,svc

bash scripts/expose-route.sh
bash scripts/check-policies.sh
```

The helper creates an edge-TLS OpenShift Route to the **Gateway Service `parks-gw-openshift-default:80`** and aligns Gateway/HTTPRoute hostnames. **Do not route to `parks-api` directly**, which would bypass RHCL policies. The Gateway Service is `parks-gw-openshift-default`, **not** `parks-gw`. No port forwarding is needed for the public demo.

**Every time you reapply `rhcl-parks-demo.yaml`, rerun `bash scripts/expose-route.sh`** to reset the Gateway/HTTPRoute placeholder hostname.

```bash
export PARKS_URL="https://$(oc -n rhcl-parks-demo get route parks-api-gateway -o jsonpath='{.spec.host}')"
echo "$PARKS_URL"
oc -n rhcl-parks-demo describe authpolicy parks-auth
oc -n rhcl-parks-demo describe ratelimitpolicy parks-rate-limits
```

**Both policies must have `Accepted=True` and `Enforced=True` before testing security.** A `200` alone proves only routing, not authentication.

> **Lab TLS:** All `curl` examples use `-k` because this sandbox Route certificate is untrusted by the Mac. `-k` skips server verification; **do not use it in production**. Use a trusted certificate or `curl --cacert`. See [curl TLS certificate guidance](https://curl.se/docs/sslcerts.html).

## 3. HTTP codes: 200, 400, 401, 404

```bash
printf '\nValid API key — expect 200\n'
curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' \
  "$PARKS_URL/ws/data/all"

printf '\nMissing name parameter — expect 400\n'
curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' \
  "$PARKS_URL/ws/data/park"

printf '\nNo API key — expect 401 from Authorino\n'
curl -k -i "$PARKS_URL/ws/info/"

printf '\nUnknown park — expect 404\n'
curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' \
  "$PARKS_URL/ws/data/park?name=Atlantis"
```

`400` and `404` originate in the sample application and pass through the gateway; `401` comes from RHCL authorization. The API keys in the YAML are **public demo-only** strings.

## 4. Per-client burst and sustained limits: HTTP 429

| Client | Per 10 seconds | Per minute |
| --- | ---: | ---: |
| Alice | 5 | 15 |
| Bob | 2 | 6 |
| Benchmark | 10,000 | 100,000 |

**Required preflight:** In your latest lab run, the policy reported:

```text
Accepted = True
Enforced = False | Overridden |
RateLimitPolicy is overridden by [rhcl-parks-demo/parks-plans]
```

That explains why **every Alice/Bob request returned 200**. The `parks-plans` **PlanPolicy** was attached to the same HTTPRoute and took precedence. The test below proves `429` **only if `parks-rate-limits` is actually Enforced=True**.

```bash
oc -n rhcl-parks-demo get planpolicy
oc -n rhcl-parks-demo describe planpolicy parks-plans
oc -n rhcl-parks-demo get ratelimitpolicy parks-rate-limits \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'
```

**Pick ONE mode:**

1. **Plan-tier demonstration:** Keep `parks-plans` and test its Bronze/Silver/Gold tier limits. See its `spec.plans` and statuses; **do not expect Alice/Bob's separate RateLimitPolicy counters to apply**. A plan-level quota may be shared across subscribers in a tier.
2. **Original Alice/Bob demonstration:** Only if `parks-plans` belongs **exclusively to this disposable lab** and you can safely interrupt its tier policies, temporarily remove it. First make a *clean backup*, then delete the specifically named PlanPolicy:

```bash
oc -n rhcl-parks-demo get planpolicy parks-plans -o json \
  | jq 'del(.status,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields)' \
  > /tmp/rhcl-parks-plans-backup.json
if [[ -s /tmp/rhcl-parks-plans-backup.json ]] && \
   jq -e '.kind=="PlanPolicy" and .metadata.name=="parks-plans" and .metadata.namespace=="rhcl-parks-demo"' \
      /tmp/rhcl-parks-plans-backup.json >/dev/null; then
  oc -n rhcl-parks-demo delete planpolicy parks-plans
  oc -n rhcl-parks-demo wait ratelimitpolicy/parks-rate-limits \
    --for=condition=Enforced=True --timeout=180s
else
  echo 'STOP: PlanPolicy backup missing/invalid; nothing deleted.'
fi
```

If you don't own `parks-plans`, **do not delete it**; ask the owner or use a separate lab route. **Run the Bob/Alice tests below only when `parks-rate-limits` is Enforced=True.** When done, use the restore commands at the end of this section. [RHCL PlanPolicy documentation](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/rhcl-planpolicy).

**Bob:** with fresh limits expect **2×200, then 6×429**.

```bash
for i in {1..8}; do
  curl -k -sS -o /dev/null -w "Bob $i: HTTP %{http_code}\n" \
    -H 'Authorization: APIKEY bob-parks-demo-key' \
    "$PARKS_URL/ws/data/all"
done
```

**Alice:** with fresh limits expect **5×200, then 3×429**.

```bash
for i in {1..8}; do
  curl -k -sS -o /dev/null -w "Alice $i: HTTP %{http_code}\n" \
    -H 'Authorization: APIKEY alice-parks-demo-key' \
    "$PARKS_URL/ws/data/all"
done
```

**Sustained Alice (15/minute):** wait ~65 seconds for previous counters, send three batches separated by 11 seconds, then a 16th request in the 1-minute window:

```bash
for batch in 1 2 3; do
  for i in {1..5}; do
    curl -k -sS -o /dev/null -w '%{http_code} ' \
      -H 'Authorization: APIKEY alice-parks-demo-key' \
      "$PARKS_URL/ws/info/"
  done
  echo
  sleep 11
done
curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' \
  "$PARKS_URL/ws/info/"
```

Expected final `429`, assuming counters were fresh. These are **short + sustained windows**, not a token-bucket implementation.

**Restore the plan after the Alice/Bob tests** (only if you backed it up and removed it above):

```bash
oc apply -f /tmp/rhcl-parks-plans-backup.json
oc -n rhcl-parks-demo describe planpolicy parks-plans
oc -n rhcl-parks-demo describe ratelimitpolicy parks-rate-limits
```

The original RateLimitPolicy will likely show `Overridden` again once `parks-plans` returns. That is **expected**; don't repeat Alice/Bob rate tests without checking which policy is active.

## 5. API Products & API Keys (Technology Preview)

This optional module demonstrates **publishing an API → consumer request → owner approval → approved credential**. RHCL 1.4 API management is **Technology Preview**; publishing does not itself secure a route.

### 5A. Enable the OpenShift console plugin

```bash
oc api-resources --api-group=devportal.kuadrant.io
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}'
oc -n openshift-operators get deployment kuadrant-console-plugin
```

Expect CRDs named `APIProduct`, `APIKey`, `APIKeyRequest` and `APIKeyApproval`. If nothing appears in the console, go to **Administration → Cluster Settings → Configuration → Console → Console plugins**, enable **`kuadrant-console-plugin`**, and reload the browser. The menus are **Connectivity Link → API Products** and **Connectivity Link API Catalog → My API Keys / API Key Approvals**. The Operator/CRDs and console plugin must be healthy first.

### 5B. Publish the National Parks API

```bash
oc explain apiproduct.spec --api-version=devportal.kuadrant.io/v1alpha1
oc apply --dry-run=server -f docs/api-product.yaml
oc apply -f docs/api-product.yaml
oc -n rhcl-parks-demo get apiproduct national-parks-api -o yaml
oc -n rhcl-parks-demo get apiproduct national-parks-api \
  -o jsonpath='{.spec.documentation.docsURL}{"\n"}'
```

The Product `National Parks API v1.0.0` targets **HTTPRoute `rhcl-parks-demo/parks-api`**, uses [OpenAPI spec](docs/openapi.yaml), and requires **manual key approval**. The `docsURL` should now end in `/blob/main/README.md`, not the deleted `docs/API-Products-and-API-Keys.md`; if it is still old, refresh your local clone and reapply **only** `docs/api-product.yaml`. If your Tech Preview CRD rejects a field, read the dry-run message and `oc explain`; don't force a CRD change.

### 5C. Request, approve, test and revoke a key

1. If necessary, create a consumer namespace: `oc create namespace rhcl-parks-consumer` (skip if it already exists).
2. Select namespace **`rhcl-parks-consumer`** in OpenShift Console → **Connectivity Link API Catalog → My API Keys → Request API Key** → choose **National Parks API** → key name `parks-consumer-demo` → submit. Expected **Pending**.
3. Switch to **`rhcl-parks-demo`** → **API Key Approvals** → inspect and **Approve**.
4. Switch back to `rhcl-parks-consumer` → **My API Keys** → open the approved key → **Show API Key**.

**Stop if the request has not actually been approved.** In your last output the `APPROVED` column for `test-key` was blank, and no APIKeyApproval was listed. Review the request in the owner namespace before testing the data plane.

Observe request/approval objects without exposing credentials:

```bash
oc -n rhcl-parks-demo get apikeyrequests,apikeyapprovals
oc -n rhcl-parks-consumer get apikeys
oc -n rhcl-parks-consumer describe apikey test-key
```

Copy the newly approved credential to your terminal without putting its value in shell history:

```bash
printf 'Approved Parks API key: '
read -rs PARKS_API_KEY
printf '\n'
if [[ -z "$PARKS_API_KEY" ]]; then
  printf 'STOP: no API key was entered. Check approval and retry.\n'
else
  curl -k -i -H "Authorization: APIKEY $PARKS_API_KEY" \
    "$PARKS_URL/ws/data/all"
fi
unset PARKS_API_KEY
```

If you chose a key name other than `test-key`, substitute your own name in the `describe` command.

**Expected 200 requires the actual generated Secret to be discoverable by `parks-auth`**, including its namespace, `app: parks-api` label and the `APIKEY` prefix. If it returns `401`, inspect the managed Secret's **metadata**, not its value; API Product approval does not automatically fix the data-plane policy. Revoke the approved key in the console, then confirm denial.

Separate-team RBAC can use the documented `api-catalog-browser`, `api-consumer` and `api-owner` roles; a cluster-admin demo does **not** prove tenant separation. The repo does not ship a PlanPolicy manifest, but your cluster **does** have `parks-plans`. This active plan policy overrides Alice/Bob's original rate-limit demo; inspect its tier configuration separately. New consumer keys do not automatically inherit Bob/Alice quotas.

## 6. JWT validation with Red Hat build of Keycloak

This adds a second secure path **`/jwt/ws/data/all`** on the **same Gateway**. The original **`/ws/data/all`** still accepts the example API keys. A dedicated HTTPRoute rewrites `/jwt` to the same backend endpoint. Keycloak runs on its own Route and issues JWT access tokens.

### 6A. Deploy Keycloak and JWT policies

```bash
bash scripts/setup-jwt-demo.sh
oc -n rhcl-parks-demo rollout status deployment/parks-keycloak --timeout=300s
oc -n rhcl-parks-demo describe authpolicy parks-jwt-auth
oc -n rhcl-parks-demo describe ratelimitpolicy parks-jwt-rate-limits
```

**Stop** unless *both* JWT policies show `Accepted=True` and `Enforced=True`. This deploys [Keycloak](docs/keycloak-lab.yaml), [realm/client configuration](docs/keycloak-realm.json) and [JWT policy](docs/jwt-protection-template.yaml). Keycloak `start-dev` is ephemeral and **not HA/production-ready**. The script generates a bootstrap admin Kubernetes Secret; no passwords are in Git.

### 6B. Obtain the OAuth client secret

```bash
export KC_URL="https://$(oc -n rhcl-parks-demo get route parks-keycloak -o jsonpath='{.spec.host}')"
export PARKS_URL="https://$(oc -n rhcl-parks-demo get route parks-api-gateway -o jsonpath='{.spec.host}')"
echo "$KC_URL"

oc -n rhcl-parks-demo get secret parks-keycloak-bootstrap \
  -o jsonpath='{.data.password}' | base64 -D
echo
```

Open `$KC_URL`, log in as **admin**, select the **parks** realm, then **Clients → parks-demo-client**. Verify:

- **Client authentication: On**.
- **Service accounts roles: enabled** (required for the `client_credentials` grant).
- **Credentials → Client secret** is the **current** secret for `parks-demo-client`.

**Client secret ≠ admin password.** Your latest run returned `unauthorized_client` / `Invalid client or Invalid client credentials`: **fix that at Keycloak before running any JWT API calls**. This lab uses Keycloak development mode with ephemeral data. A restart may recreate its client secret, so an earlier working secret can go stale. Never paste the admin password or JWT in shared logs; if you already shared the lab admin password, rotate it in Keycloak.

In a terminal, paste the client secret without displaying it:

```bash
printf 'Paste current parks-demo-client secret: '
read -rs KC_CLIENT_SECRET
printf '\n'
if [[ -z "$KC_CLIENT_SECRET" ]]; then
  echo 'STOP: client secret is blank. Copy it from Keycloak Credentials.'
fi
```

### 6C. Request a signed token (120-second lifetime)

```bash
unset ACCESS_TOKEN
TOKEN_JSON="$(curl -ksS -X POST \
  "$KC_URL/realms/parks/protocol/openid-connect/token" \
  -d grant_type=client_credentials \
  -d client_id=parks-demo-client \
  --data-urlencode "client_secret=$KC_CLIENT_SECRET")"

printf '%s\n' "$TOKEN_JSON" | jq '{error, error_description, expires_in, token_type}'
ACCESS_TOKEN="$(printf '%s' "$TOKEN_JSON" | jq -r '.access_token // empty')"
unset KC_CLIENT_SECRET TOKEN_JSON
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo 'STOP: no JWT issued. Fix Keycloak client auth/secret before Section 6D.'
else
  echo 'JWT received; run Section 6D immediately (120s token lifetime).'
fi
```

Expected: no error, `token_type: "Bearer"`, `expires_in: 120` and the message **JWT received**. **If you see `unauthorized_client`, `invalid_client`, or `STOP`, do not run Section 6D:** an empty bearer token produces `401` every time, which proves nothing about JWT validation. Recheck Keycloak's client secret, authentication switch and service-account setting. **Do not paste the JWT or client secret into tickets/GitHub/chat.**

Optional: decode *selected claims* for display (decoding is **not validation**):

```bash
printf '%s' "$ACCESS_TOKEN" | cut -d. -f2 | tr '_-' '/+' \
  | awk '{ while (length($0) % 4) $0 = $0 "="; print }' \
  | base64 -D | jq '{iss, aud, sub, iat, exp}'
```

Check `iss` matches `$KC_URL/realms/parks`, `aud` includes `parks-api` and `exp - iat` is about 120 seconds. **Authorino**, not a local decode, verifies JWT signature and expiration against Keycloak JWKS. The AuthPolicy separately checks issuer and audience: RHCL 1.4.3 silently dropped an earlier `jwt.audiences` field, so these claims are validated using explicit authorization rules.

### 6D. Prove 200, 401 and 429

**Prerequisite:** Section 6C must have printed **JWT received**, and `ACCESS_TOKEN` must not be empty. Run immediately after issuance (the token expires in **120 seconds**); rerun Section 6B–6C if needed. A blank or expired token makes all eight attempts return `401`, **not** a meaningful `429` demonstration.

```bash
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo 'STOP: ACCESS_TOKEN is empty. Fix Keycloak and repeat Section 6C.'
else
  printf '\nValid JWT — expect 200\n'
  curl -k -i -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$PARKS_URL/jwt/ws/data/all"

  printf '\nMissing JWT — expect 401\n'
  curl -k -i "$PARKS_URL/jwt/ws/data/all"

  printf '\nWrong authorization scheme — expect 401\n'
  curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' \
    "$PARKS_URL/jwt/ws/data/all"

  printf '\n8 rapid JWT calls — expect 429 after initial 200s\n'
  for i in {1..8}; do
    curl -k -sS -o /dev/null -w "JWT $i: HTTP %{http_code}\n" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$PARKS_URL/jwt/ws/data/all"
  done

  printf '\nOriginal API-key path — expect 200\n'
  curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' \
    "$PARKS_URL/ws/data/all"
fi
```

JWT limits: **5/10s per `sub`**, **20/min per `sub`**, **60/min aggregate**. Confirm `parks-jwt-auth` and `parks-jwt-rate-limits` are both `Accepted=True` and `Enforced=True`; they were healthy in the most recent run. Prior calls can consume quota, so the eight rapid responses may contain fewer than five initial `200`. After 120 seconds, the old token should yield `401`; **issue a new token for another 429 test**.

### 6E. What Keycloak/RHCL validates and manages

- **Issue/renew:** Keycloak handles OAuth2 `client_credentials`; RHCL does not mint JWTs. Service accounts request new access tokens when they expire.
- **Authentication:** Authorino validates signed JWTs using a cached Keycloak JWKS, signing key identifier (`kid`), signature and expiry.
- **Authorization:** Explicit AuthPolicy rules require the Keycloak Route **issuer** and `parks-api` **audience** (wrong signed claims are rejected, typically `403`).
- **Rate limits:** Limitador groups by authenticated JWT `sub` and enforces a shared aggregate cap.
- **Rotation/revocation:** Rotate OAuth client secrets and Keycloak signing keys in Keycloak. Disabling a client does **not guarantee immediate revocation** of a previously issued stateless JWT; short TTL limits exposure.
- **Production caveat:** Lab JWKS URL uses **in-cluster HTTP** because public Route TLS was untrusted; production needs trusted HTTPS/mTLS and network restrictions. The lab Keycloak uses development-mode ephemeral storage.

**Known RHCL 1.4.3 defect:** On this cluster, the header `Authorization: Bearer invalid.invalid.invalid` led to **HTTP 504**, despite Authorino rejecting it. The gateway's `kuadrant_wasm_shim` panicked on a CEL parse error. **Do not use that malformed value as the normal `401` test or claim it passed security validation.** Use the demonstrated missing/expired-token cases. Collect proxy and Authorino logs and open a Red Hat support case for this malformed-token behavior.

## 7. Optional performance measurement

With a trusted Route certificate and the `hey` HTTP load-testing tool:

```bash
hey -n 1000 -c 10 \
  -H 'Authorization: APIKEY benchmark-parks-demo-key' \
  "$PARKS_URL/ws/data/all"
```

Record requests/second, errors, p50/p95/p99. The benchmark identity has a deliberately high quota. **If `parks-plans` currently overrides the original RateLimitPolicy, this tests the active plan-policy configuration, not Alice/Bob's configured quotas.** **`hey` does not use `curl -k`**: fix certificate trust or configure your benchmarking tool's TLS settings explicitly for lab testing.

For a *rough* backend baseline, open a second terminal with:

```bash
oc -n rhcl-parks-demo port-forward svc/parks-api 18081:8080
```

Then benchmark `http://127.0.0.1:18081/ws/data/all`. **Caveat:** the two paths have different TLS and network hops; this comparison is **not an isolated measure of RHCL overhead**. For customer SLAs, compare equivalent paths and loads.

## 8. Optional tracing and WAF / DDoS protection

### OpenTelemetry

The base lab **does not install** OpenTelemetry Collector, Tempo, or Grafana:

```bash
oc api-resources | grep -Ei 'opentelemetrycollector|tempo|telemetry|istio'
oc get istio -A
```

To demonstrate traces, deploy a supported collector/tracing backend, then configure an **independently managed** Service Mesh gateway with:

1. An Istio `meshConfig.extensionProviders` OpenTelemetry provider to OTLP/gRPC port `4317`.
2. An Istio `Telemetry` object with appropriate gateway tracing sampling.
3. Kuadrant `spec.observability.tracing.defaultEndpoint` and, if supported, Authorino/Limitador `spec.tracing.endpoint`.
4. Parks application instrumentation if you need spans *inside* the Python handler.

Send a unique `x-request-id` and correlate spans; there may be parent trace propagation gaps through WASM/Limitador. **Do not edit the OpenShift-managed `openshift-default` Istio control plane** for this POC. See [RHCL observability docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/observability/rhcl-observability).

### WAF and DDoS

**RHCL authentication and rate limits are application-layer controls, not volumetric DDoS prevention.** A flood can exhaust the network, load balancers, ingress or Keycloak before gateway quota checks.

For an AWS design: add WAF rules at CloudFront or an Application Load Balancer (**AWS WAF cannot attach directly to an NLB**), review AWS Shield, protect the **Keycloak Route**, and prevent public bypass of **both** the OpenShift router and the separate automatically created Gateway AWS LoadBalancer. Preserve expected Host/SNI.

If you have deployed an external WAF, this is the safe acceptance test:

- [ ] Normal authenticated API call through the WAF returns `200`.
- [ ] A benign demo header rule (for example `X-Demo-Block: true`) blocks the call and records a WAF event.
- [ ] The same WAF entry point still returns RHCL `401` for no key and `429` when throttled.
- [ ] Attempts to bypass the WAF to origin are denied.

**No WAF/Shield/firewall rules are provisioned by this repo; do not run attack traffic against shared clusters.**

## 9. Troubleshooting

Start with non-secret checks:

```bash
bash scripts/check-policies.sh
oc get kuadrant -A
oc get authorino,limitador -A
oc -n rhcl-parks-demo get route,gateway,httproute
oc -n rhcl-parks-demo describe authpolicy parks-auth
oc -n rhcl-parks-demo describe ratelimitpolicy parks-rate-limits
oc -n rhcl-parks-demo logs deployment/parks-api --tail=60
```

| Symptom | What to check |
| --- | --- |
| `Invalid / Not Accepted` or `MissingDependency` | Need Ready Kuadrant plus Authorino/Limitador, not only RHCL Operator CSV. |
| API responds `200` **without** required key/token | **Stop** — bypass or unenforced AuthPolicy; no security demo until fixed. |
| `404` | Route, Gateway listener and HTTPRoute hostnames must agree; rerun `scripts/expose-route.sh`. |
| `503` | Gateway `Programmed=True` and backend endpoints/Pods Ready. |
| No `429` | Policy `Enforced=True`, correct authenticated identity and fresh counters. |
| API Products absent from console | Enable `kuadrant-console-plugin`; inspect `devportal.kuadrant.io` CRDs. |
| Approved API Product key yields `401` | Check generated Secret labels/namespace, `parks-auth` selector, `APIKEY` prefix. |
| Keycloak `invalid_client` | The OAuth **client** secret is different from the bootstrap admin password. |
| JWT `403` | Compare actual token `iss` and `aud` to Keycloak Route and `parks-api`. |
| JWT loop returns only `401` | Token TTL is just 120 seconds; issue a fresh token. |
| Garbage bearer token `504` | Known RHCL 1.4.3 WASM-shim bug (above); preserve logs and open support case. |
| TLS/certificate validation fails | For lab only, use `curl -k`; production requires trusted Route TLS. |

**Old policy conflict:** If `oc apply` reports `Implicit and explicit defaults are mutually exclusive`, inspect `parks-auth`. Only when the live policy incorrectly has both `spec.defaults` and `spec.rules`, remove *only* obsolete defaults:

```bash
oc -n rhcl-parks-demo get authpolicy parks-auth -o yaml
oc -n rhcl-parks-demo patch authpolicy parks-auth --type=json \
  -p='[{"op":"remove","path":"/spec/defaults"}]'
oc apply -f rhcl-parks-demo.yaml
bash scripts/expose-route.sh
bash scripts/check-policies.sh
```

The patch does not remove your API-key Secrets; do **not** run it if `spec.defaults` is absent.

For JWT troubleshooting:

```bash
oc -n rhcl-parks-demo get httproute parks-jwt -o yaml
oc -n rhcl-parks-demo describe authpolicy parks-jwt-auth
oc -n rhcl-parks-demo describe ratelimitpolicy parks-jwt-rate-limits
oc -n rhcl-parks-demo logs deployment/parks-keycloak --tail=100
```

## 10. Cleanup, only when finished

**This deletes the entire lab namespace**, including Parks, Keycloak and lab Secrets:

```bash
oc delete namespace rhcl-parks-demo
```

If you also created `rhcl-parks-consumer`, review its contents before separately removing it. **Do not delete** the shared GatewayClass or Kuadrant instance.

## Repository files

| File | Purpose |
| --- | --- |
| [rhcl-parks-demo.yaml](rhcl-parks-demo.yaml) | Parks app, Gateway, API-key Secrets, AuthPolicy and RateLimitPolicy |
| [scripts/expose-route.sh](scripts/expose-route.sh) | Create HTTPS Route and align Gateway/HTTPRoute hostnames |
| [scripts/check-policies.sh](scripts/check-policies.sh) | Read-only policy and component diagnostics |
| [scripts/test-all.sh](scripts/test-all.sh) | One-command, read-only PASS/FAIL/SKIP validation runner |
| [scripts/setup-jwt-demo.sh](scripts/setup-jwt-demo.sh) | Add lab Keycloak, JWT HTTPRoute and policies |
| [docs/keycloak-lab.yaml](docs/keycloak-lab.yaml), [docs/keycloak-realm.json](docs/keycloak-realm.json) | Keycloak deployment and sample realm |
| [docs/jwt-protection-template.yaml](docs/jwt-protection-template.yaml) | JWT AuthPolicy and rate-limit configuration |
| [docs/api-product.yaml](docs/api-product.yaml), [docs/openapi.yaml](docs/openapi.yaml) | Product catalog object and API specification |

## Official documentation

- [RHCL 1.4 installation](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/install_connectivity_link/rhcl-install-on-ocp)
- [RHCL authentication and policies](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/connect-secure-apis-services)
- [RHCL API Products and API Keys](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/develop_apis_with_the_web_console/rhcl-api-management)
- [RHCL OIDC/JWT](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/rhcl-oidc-authentication)
- [RHCL observability](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/observability/rhcl-observability)
- [Red Hat build of Keycloak](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/server_guide/)
- [OpenShift 4.22 Gateway API](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/configuring-gateway-api)
- [AWS WAF](https://docs.aws.amazon.com/waf/latest/developerguide/how-aws-waf-works.html)
