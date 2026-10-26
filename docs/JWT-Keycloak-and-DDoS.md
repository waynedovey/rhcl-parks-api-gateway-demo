# JWT security with Red Hat build of Keycloak — National Parks API

This optional extension adds a **JWT-secured endpoint** to the existing RHCL Parks demo. It works with the existing OpenShift HTTPS Route and keeps the API-key and API Product demonstrations separate.

> **Status:** Ready-to-apply lab configuration for RHCL Operator 1.4.3 and OpenShift 4.22.18. The repository manifests are checked against official Kuadrant/Red Hat examples, but **must be verified on your cluster** using the checks below. Never claim JWT protection is active until `AuthPolicy` and `RateLimitPolicy` report `Accepted=True` and `Enforced=True`, and the negative tests reject requests.

## What you will demonstrate

| Requirement | How this lab shows it | Expected outcome |
| --- | --- | --- |
| JWT token management | Keycloak realm and OAuth2 `client_credentials` client; short-lived access tokens | Keycloak issues a signed token valid for 120 seconds |
| JWT signature and expiry validation | Authorino verifies the JWT against Keycloak JWKS | Invalid, tampered, expired or missing token → 401 |
| Issuer validation | Kuadrant checks the signed `iss` claim equals the public Keycloak realm URL | Wrong issuer → 403 (authorization denial) |
| Audience validation | AuthPolicy requires `aud: parks-api` | Wrong audience → 401 |
| Valid authenticated API request | Existing Parks app under a dedicated `/jwt` path | 200 |
| Client-specific throttling | JWT `sub` forwarded to Limitador; 5/10s and 20/min per client | 429 when limits are exceeded |
| Aggregate throttling | Global 60/min for JWT API route | 429 above shared allowance |
| DDoS resilience | Defense-in-depth design with AWS WAF/Shield + network controls | Requires separate AWS configuration; **not provided by RHCL alone** |

## Architecture

```text
Client                 OpenShift HTTPS Route                   Parks API
  |                             |                                  ^
  +--- GET /jwt/ws/data/all ---> +-- RHCL Gateway / HTTPRoute -----+
                                      |           |
                                      |           +--- Limitador rate limits
                                      +--- Authorino JWT validation
                                               |
                                               +--- Internal JWKS URL from Keycloak

Machine-to-machine client --- HTTPS ---> Keycloak Route
                          client_id + secret → signed access_token
```

- `/ws/data/all` remains on `parks-api` HTTPRoute protected by API keys.
- `/jwt/ws/data/all` is matched by the more-specific **`parks-jwt` HTTPRoute**, checks JWT, then rewrites the prefix to `/ws/data/all` for the unchanged Parks app.
- Both endpoints use your **existing** Gateway `parks-gw` and Route `parks-api-gateway`. No additional Parks Gateway LoadBalancer is created.
- Keycloak has its own Route only for the token service and admin console.

## 1. Prerequisites

Run from your local clone, logged into the same OpenShift 4.22.18 cluster:

```bash
oc whoami
oc -n rhcl-parks-demo get gateway parks-gw
oc -n rhcl-parks-demo get route parks-api-gateway
oc get kuadrant -A
oc get authorino,limitador -A
```

The original API and HTTPS Route must already exist. If not:

```bash
oc apply -f rhcl-parks-demo.yaml
bash scripts/expose-route.sh
```

Do not continue if Kuadrant, Authorino or Limitador is absent or unhealthy; that leaves requests unprotected. Follow the [main README](../README.md#1-check-prerequisites) to create the Kuadrant CR in the RHCL Operator namespace.

You will need `oc`, `openssl`, `sed`, `curl` and `jq` on your Mac. You must have permissions to create resources in `rhcl-parks-demo`, and a cluster pull secret that can access the Red Hat registry image `registry.redhat.io/rhbk/keycloak-rhel9:26.4`.

## 2. Deploy Keycloak, a realm and RHCL JWT policies

```bash
git pull --ff-only
bash scripts/setup-jwt-demo.sh
```

The script:

1. Confirms the existing Parks Gateway/Route agree on hostnames and a Kuadrant instance exists.
2. Creates a random Keycloak bootstrap administrator password in the Kubernetes Secret `parks-keycloak-bootstrap` (never stored in GitHub).
3. Imports the `parks` realm with a confidential `parks-demo-client` service account client, 120-second access tokens and custom audience `parks-api`.
4. Starts Red Hat build of Keycloak in **development mode**, creates its HTTPS OpenShift Route, sets its public issuer hostname and waits for its Deployment.
5. Adds an HTTPRoute for `/jwt`, an `AuthPolicy` that validates signed bearer tokens, and a `RateLimitPolicy`.

Rerunning the script reuses the existing bootstrap Secret/Route and updates the lab configuration. **Important:** this is a single-node Keycloak development installation with an in-memory database. If the pod restarts, clients or secrets may be recreated and existing tokens stop working. This is an intentionally disposable lab, **not** a supported production topology.

Check deployed resources:

```bash
oc -n rhcl-parks-demo get deployment parks-keycloak
oc -n rhcl-parks-demo get route parks-api-gateway parks-keycloak
oc -n rhcl-parks-demo get httproute parks-jwt -o yaml
oc -n rhcl-parks-demo describe authpolicy parks-jwt-auth
oc -n rhcl-parks-demo describe ratelimitpolicy parks-jwt-rate-limits
```

For both JWT policies, look for `Accepted=True` and `Enforced=True` (the conditions can take a little time to reconcile). If either is `False`, **stop** and diagnose it before demonstrating security.

## 3. Retrieve a Keycloak client secret

Open the Keycloak URL printed by the setup script, or display it:

```bash
export KC_URL="https://$(oc -n rhcl-parks-demo get route parks-keycloak -o jsonpath='{.spec.host}')"
export PARKS_URL="https://$(oc -n rhcl-parks-demo get route parks-api-gateway -o jsonpath='{.spec.host}')"
echo "$KC_URL"
```

Retrieve the **lab admin password** on macOS (do not publish or paste it into GitHub):

```bash
oc -n rhcl-parks-demo get secret parks-keycloak-bootstrap -o jsonpath='{.data.password}' | base64 -D
```

In the Keycloak console:

1. Log in as `admin` using the generated password.
2. Switch from the `master` realm to the **`parks`** realm.
3. Open **Clients → parks-demo-client → Credentials**.
4. Copy the **Client secret** from the Credentials page.

Set the secret in your terminal **without putting it in your shell history**:

```bash
read -rs KC_CLIENT_SECRET
# Paste the value and press Enter (typing will not echo).
echo
```

The `client_id` is `parks-demo-client`. Do not store the client secret, JWT or bootstrap password in Git.

## 4. Obtain and inspect a JWT

Ask Keycloak for an access token using the OAuth2 client credentials flow:

```bash
TOKEN_JSON="$(curl -ksS --fail-with-body -X POST \
  "$KC_URL/realms/parks/protocol/openid-connect/token" \
  -d grant_type=client_credentials \
  -d client_id=parks-demo-client \
  --data-urlencode "client_secret=$KC_CLIENT_SECRET")"

ACCESS_TOKEN="$(printf '%s' "$TOKEN_JSON" | jq -r '.access_token // empty')"
unset KC_CLIENT_SECRET TOKEN_JSON
test -n "$ACCESS_TOKEN" || { echo 'Token issuance failed'; exit 1; }
```

`curl -k` is only for this sandbox's untrusted route certificate. Install trusted certificates for real deployments; `-k` disables server identity verification.

To see only the relevant non-secret JWT claims (this is **decoding, not validation**):

```bash
printf '%s' "$ACCESS_TOKEN" | cut -d. -f2 | tr '_-' '/+' \
  | awk '{ while (length($0) % 4) $0 = $0 "="; print }' \
  | base64 -D | jq '{iss, aud, sub, iat, exp}'
```

Verify:

- `iss` is **exactly** `$KC_URL/realms/parks`.
- `aud` contains **`parks-api`**.
- `exp` is approximately 120 seconds after `iat`.
- `sub` identifies the Keycloak service-account identity.

**Never trust decoded claims alone.** Authorino verifies the cryptographic signature against Keycloak's current signing keys, confirms expiration and the configured audience; a separate authorization rule checks the issuer.

## 5. Demonstrate the status codes

Make sure `KC_URL`, `PARKS_URL` and `ACCESS_TOKEN` are set and the policies are enforced.

**Valid JWT → HTTP 200:**

```bash
curl -k -i -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$PARKS_URL/jwt/ws/data/all"
```

**Missing JWT → HTTP 401:**

```bash
curl -k -i "$PARKS_URL/jwt/ws/data/all"
```

**Tampered/invalid JWT → HTTP 401:**

```bash
curl -k -i -H 'Authorization: Bearer invalid.invalid.invalid' \
  "$PARKS_URL/jwt/ws/data/all"
```

**Try an API key on the JWT route → HTTP 401:**

```bash
curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' \
  "$PARKS_URL/jwt/ws/data/all"
```

**Existing API-key demo should still work → HTTP 200:**

```bash
curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' \
  "$PARKS_URL/ws/data/all"
```

If *any* call to `/jwt` returns 200 without a valid bearer token, security is not enforced. Stop and check policies and Gateway attachments.

## 6. Demonstrate JWT rate limiting → HTTP 429

With the fresh JWT obtained above, quickly run eight requests:

```bash
for i in {1..8}; do
  curl -k -sS -o /dev/null -w "Request $i: %{http_code}\n" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$PARKS_URL/jwt/ws/data/all"
done
```

Expect no more than five successes in a fresh ten-second window; after that the per-client limit produces `429`. Prior test calls consume part of the allowance, and a full-minute 20-request allowance may also be exhausted. The aggregate limit allows **60 JWT requests/minute** across clients. Both policies protect the application only **after** ingress and authentication stages.

Wait longer than two minutes after token issuance and repeat a valid-token call. Expect `401` for the expired token. Reissue a new token using Step 4 for further tests. The rate limit is grouped by the authenticated JWT `sub`, so two distinct service accounts would have separate per-client limits.

## 7. What is actually validated?

| Layer | Check | Component |
| --- | --- | --- |
| TLS client → router | HTTPS transport | OpenShift Router (edge TLS) |
| Authentication | Presence, signature, Keycloak signing key (`kid`), expiration, `aud=parks-api` | RHCL AuthPolicy → Authorino |
| Authorization | Exact JWT `iss` matches expected Keycloak realm | RHCL AuthPolicy → Authorino |
| Traffic control | 5/10s + 20/min per JWT `sub`; 60/min aggregate | RHCL RateLimitPolicy → Limitador |
| Backend | Parks REST endpoint and application response | Parks API |

For a production setup, prefer `jwt.issuerUrl` pointing at a trusted HTTPS Keycloak realm with an appropriately trusted CA. This sandbox deliberately uses the **in-cluster HTTP JWKS URL** to work around its untrusted public Route certificate and explicitly checks the public issuer. Protect that back-channel with network policies and TLS/mTLS in a real deployment.

### Token lifecycle and management

- **Issue:** Keycloak's token endpoint handles OAuth2 `client_credentials`; RHCL does not mint access tokens.
- **Validate:** Authorino checks JWTs locally using cached JWKS; Keycloak is not contacted on every API request.
- **Expire/renew:** The configured access-token lifetime is 120 seconds. Machine clients ask Keycloak for a new token when needed; client credentials flow normally does not rely on a refresh token.
- **Rotate:** Rotate Keycloak client secrets and realm signing keys in Keycloak, distribute new secrets securely and let Authorino refresh JWKS on new `kid`.
- **Revoke:** Disabling a client or rotating its client secret does **not necessarily invalidate existing stateless JWTs immediately**. Short TTL limits exposure. If strict instant revocation is required, design for introspection, sessions or additional server-side revocation logic.

## 8. DDoS mitigation — required perimeter layers

**RHCL AuthPolicy and RateLimitPolicy are not a substitute for volumetric DDoS protection.** A flood can consume ingress, LoadBalancer, network, CPU and Keycloak resources *before* a valid JWT or rate limit is evaluated.

For the AWS OpenShift lab, design these layers before exposing a production application:

1. **AWS edge:** Front the application with an appropriate CloudFront or Application Load Balancer design and attach **AWS WAF** rate-based, managed and IP reputation rules. AWS WAF cannot be attached directly to a Network Load Balancer (NLB). Verify the exact OpenShift Route/Gateway LB topology before implementing.
2. **AWS Shield:** Confirm Shield protections and escalation/operational requirements appropriate to the public entry points. For advanced support, evaluate Shield Advanced.
3. **Prevent bypass:** The original OpenShift Router LB *and* the Gateway's independent AWS LoadBalancer may be publicly addressable. Ensure the perimeter can reach the origin but clients cannot bypass WAF using the unprotected LB/Route, IP or direct DNS. Preserve the expected `Host` and SNI when proxying.
4. **Protect Keycloak too:** Apply WAF/bot/rate controls to the token endpoint; consider restricting administrative access, adding OAuth client credential rotation, avoiding public admin endpoints, and setting upstream request/connection limits.
5. **Defense at RHCL:** Keep signature, issuer, audience checks and per-client + aggregate rate limits; monitor 401/403/429 spikes and request latency. Unauthenticated floods need controls **before** Authorino.
6. **Resilience:** Use Keycloak HA, PostgreSQL, multiple replicas where topology supports it, observability, autoscaling, resource quotas and reasonable timeouts in production.

The GitHub YAML deploys **only** the RHCL policies and lab Keycloak. **No AWS WAF, Shield, origin firewall or attack traffic generator is provisioned.** The benign 8-request loop above demonstrates 429 behavior; do not run volumetric attacks against shared clusters.

## 9. Troubleshooting

| Symptom | Check |
| --- | --- |
| `AuthPolicy` or `RateLimitPolicy` says `MissingDependency` | `oc get kuadrant -A`, `oc get authorino,limitador -A`; complete RHCL installation first |
| `ImagePullBackOff` on Keycloak | Entitlement/pull secret access to `registry.redhat.io` |
| Keycloak pod not Ready | `oc -n rhcl-parks-demo logs deploy/parks-keycloak`; confirm the realm import and `KC_HOSTNAME` |
| Keycloak token endpoint `400` / `401` | Use `parks` realm, correct client secret; check service accounts enabled |
| Missing `parks-api` audience | Check Clients → Client scopes/mappers or imported client `parks-api-audience`; fetch a fresh token |
| JWT route `404` | `oc -n rhcl-parks-demo get httproute parks-jwt -o yaml`; confirm Gateway listener host and existing Parks Route |
| Correct JWT gets `401` | Check `aud`, signature, expiration, Keycloak JWKS reachability and Authorino logs |
| Correct JWT gets `403` | Compare `iss` with `https://<keycloak-route-host>/realms/parks` exactly |
| Missing token still gets `200` | **Stop.** Policies are not enforced / route bypasses Gateway |
| No `429` | Check rate limit `Enforced=True` and identity filter `auth.identity.userid` |
| Router TLS certificate error | `-k` for this lab only; use a trusted certificate for production |

To inspect status and failures:

```bash
oc -n rhcl-parks-demo get httproute parks-jwt -o yaml
oc -n rhcl-parks-demo get authpolicy parks-jwt-auth -o yaml
oc -n rhcl-parks-demo get ratelimitpolicy parks-jwt-rate-limits -o yaml
oc -n rhcl-parks-demo logs deployment/parks-keycloak --tail=100
oc get authorino,limitador -A
```

**Portal note:** This extension is a distinct JWT-protected `HTTPRoute`. It does **not automatically publish** a second API Product or issue API keys. If you want an OIDC product in the developer portal later, publish `parks-jwt` separately. For API Products in RHCL 1.4, the `AuthPolicy` should expose the JWT authentication rule under `spec.rules.authentication` so the discovery controller can find it.

## Files

- [Keycloak realm](keycloak-realm.json) — client and token settings; no credentials stored.
- [Keycloak deployment](keycloak-lab.yaml) — disposable development-mode RHBK Deployment, Service.
- [JWT policy template](jwt-protection-template.yaml) — HTTPRoute, AuthPolicy and RateLimitPolicy; setup script sets correct `iss`.
- [Setup script](../scripts/setup-jwt-demo.sh) — installation and Route creation.

## Authoritative references

- [RHCL 1.4 OIDC authentication](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/rhcl-oidc-authentication)
- [RHCL 1.4 API management/OIDC visibility](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/develop_apis_with_the_web_console/rhcl-api-management)
- [Kuadrant: authenticated JWT rate limiting](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/user-guides/ratelimiting/authenticated-rl-with-jwt-and-k8s-authnz/)
- [Kuadrant Authorino JWT, claims and JWKS](https://docs.kuadrant.io/latest/authorino/docs/features/)
- [Red Hat build of Keycloak Server Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/server_guide/)
- [AWS WAF supported resources](https://docs.aws.amazon.com/waf/latest/developerguide/how-aws-waf-works.html)
- [AWS Shield](https://docs.aws.amazon.com/waf/latest/developerguide/shield-chapter.html)
