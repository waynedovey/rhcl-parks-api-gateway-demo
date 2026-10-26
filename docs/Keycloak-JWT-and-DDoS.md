# Module 7 — Keycloak JWT validation and API abuse protection

This is an **opt-in extension** to the existing National Parks demo (OpenShift 4.22.18, RHCL 1.4.3). It retains the original `parks-api` HTTPRoute, `parks-auth` API-key authentication, Alice/Bob limits, APIProduct and PlanPolicy.

> Lab example, **not a complete DDoS defence**. JWT validation and rate limits stop many unauthorised or over-quota API requests, but a flood can saturate network/ingress/Authorino/Keycloak before RHCL can reject it. See [Production security boundary](#production-security-boundary).

## Architecture and paths

```text
API-key caller -> HTTPS OpenShift Route -> parks-gw -> parks-api [/*]
                                                    -> existing API key policies -> Parks Service

JWT caller -> same HTTPS OpenShift Route -> parks-gw -> parks-jwt [/jwt/*]
                                                  -> JWT AuthPolicy -> RateLimitPolicy
                                                  -> URLRewrite /jwt/* to /* -> Parks Service

JWT client -> Keycloak /realms/parks token endpoint -> short-lived signed access token
```

The new `parks-jwt` HTTPRoute matches only `/jwt` and its subpaths. Gateway API chooses this more specific prefix over the existing `/` match. Its URLRewrite removes `/jwt` before calling the existing Python service. For example:

- API key: `$PARKS_URL/ws/data/all`
- JWT: `$PARKS_URL/jwt/ws/data/all`

**API Products:** The existing `national-parks-api` APIProduct still targets `parks-api` and therefore remains an API-key product. It will not automatically display this new route's JWT scheme. If you want JWT discovery in the RHCL catalog, create a **separate** APIProduct targeting `parks-jwt` after its AuthPolicy is enforced; do not repoint the existing product and disrupt its API-key demo.

**Do not reapply `rhcl-parks-demo.yaml` as part of this module.** The existing base YAML contains an example gateway hostname; the Route setup script has already patched the hostname for the live gateway. The JWT HTTPRoute deliberately omits `hostnames` and inherits the live Gateway listener hostname.

## 1. Deploy or reuse Red Hat build of Keycloak

Use Red Hat build of Keycloak 26.4 with its Operator, PostgreSQL, an HTTPS hostname/Route and a trusted TLS certificate. An example on an existing Keycloak instance works equally well, provided it is accessible to the RHCL Authorino deployment.

If you have no instance yet, follow Red Hat's [RHBK 26.4 Operator basic deployment guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/operator_guide/basic-deployment-). The Operator **does not create PostgreSQL for you**. For this example use namespace `keycloak` and a Keycloak CR named `parks-keycloak` (or adjust `keycloakCRName` and namespace in the realm-import YAML).

Verify that the actual instance is ready:

```bash
oc -n keycloak get keycloak parks-keycloak
oc -n keycloak get pods,route
```

Use a trusted HTTPS hostname such as `https://keycloak.example.com`. Avoid exposing the administration console broadly. If the cluster uses a private CA, add that CA to RHCL's trusted CA bundle as specified by the Connectivity Link OIDC documentation. **Do not disable TLS verification in Authorino.** The `-k` examples below apply only to your existing Parks demo Route.

## 2. Import the Parks realm and confidential client

The bundled `docs/jwt/keycloak-realm-import.yaml` creates:

| Setting | Value |
| --- | --- |
| Realm | `parks` |
| Client ID | `parks-demo-cli` |
| OAuth2 grant | `client_credentials` (service account) |
| Client authentication | Confidential client + generated secret |
| Token lifetime | 300 seconds (5 minutes) |
| Custom access-token audience | `parks-api` |
| Browser/password grant | Disabled for this machine client |

Generate a secret locally. Do not commit, print or share it:

```bash
PARKS_CLIENT_SECRET="$(openssl rand -hex 32)"
oc -n keycloak create secret generic parks-client-secret \
  --from-literal=secret="$PARKS_CLIENT_SECRET"
unset PARKS_CLIENT_SECRET

oc apply --dry-run=server -f docs/jwt/keycloak-realm-import.yaml
oc apply -f docs/jwt/keycloak-realm-import.yaml
oc -n keycloak get keycloakrealmimport parks-realm-import -o yaml
```

Wait for `status.conditions` to show `Done=True`. RHBK 26.4 uses `k8s.keycloak.org/v2alpha1` for `KeycloakRealmImport`.

**Already have realm `parks`?** The import will not overwrite it. Instead configure client `parks-demo-cli` using the Keycloak Admin Console: *Clients → Create client → OpenID Connect*, enable *Client authentication* and *Service accounts roles*, disable Standard/Direct access grants, and add an **Audience** protocol mapper setting `parks-api` as the *Included Custom Audience* for access tokens. Set the realm access token lifespan to five minutes and store a generated client secret in `keycloak/parks-client-secret`.

Realm imports do **not** continuously reconcile changes. After import completes you may delete the completed import CR to clean up its Job/Pod, following the RHBK Operator guide; the realm itself remains.

## 3. Confirm OIDC discovery and issuer

Set the real public Keycloak hostname (not its in-cluster Service URL):

```bash
export KEYCLOAK_ISSUER_URL="https://keycloak.example.com/realms/parks"
curl --fail --silent --show-error \
  "$KEYCLOAK_ISSUER_URL/.well-known/openid-configuration" \
  | jq '{issuer,jwks_uri,token_endpoint}'
```

The returned `issuer` must **exactly** match `KEYCLOAK_ISSUER_URL` and the JWT's `iss` claim. Both your workstation and RHCL Authorino must be able to resolve and trust this URL. JWKS discovery lets Authorino verify Keycloak's token signature and key rotation without the API application storing signing keys.

## 4. Apply the JWT route, signature/issuer/audience policy and rate limits

From the repository root:

```bash
bash scripts/deploy-jwt.sh
```

The script:

1. Validates HTTPS discovery and exact issuer.
2. Performs server-side dry-run schema checks.
3. Installs `parks-jwt` HTTPRoute, `parks-jwt-auth` AuthPolicy and `parks-jwt-rate-limits`.
4. Leaves the existing API-key and plan policies untouched.

It applies the following essential `AuthPolicy` settings to `rhcl-parks-demo/parks-jwt`:

```yaml
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: parks-jwt
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: https://keycloak.example.com/realms/parks
          audiences:
            - parks-api
```

The actual issuer is substituted from `KEYCLOAK_ISSUER_URL`; this snippet is illustrative.

Check the result:

```bash
oc -n rhcl-parks-demo describe httproute parks-jwt
oc -n rhcl-parks-demo describe authpolicy parks-jwt-auth
oc -n rhcl-parks-demo describe ratelimitpolicy parks-jwt-rate-limits
```

Require HTTPRoute `Accepted=True` and `ResolvedRefs=True`, and both policies `Accepted=True` and `Enforced=True`. If an `HTTPRoute` filter is rejected, check whether `openshift-default` supports `URLRewrite`; do not claim the test works until it is accepted.

## 5. Request a JWT and exercise the gateway

The smoke-test script reads the demo client secret from its Kubernetes Secret, requests an access token from Keycloak, and tests the existing HTTPS Parks Route:

```bash
export KEYCLOAK_ISSUER_URL="https://keycloak.example.com/realms/parks"
bash scripts/test-jwt.sh
```

Or test manually, taking care not to paste secrets into chat or source control:

```bash
export PARKS_URL="https://$(oc -n rhcl-parks-demo get route parks-api-gateway -o jsonpath='{.spec.host}')"
PARKS_CLIENT_SECRET="$(oc -n keycloak get secret parks-client-secret -o jsonpath='{.data.secret}' | base64 -d)"
JWT_TOKEN="$(curl --fail --silent --show-error -X POST \
  "$KEYCLOAK_ISSUER_URL/protocol/openid-connect/token" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode client_id=parks-demo-cli \
  --data-urlencode "client_secret=$PARKS_CLIENT_SECRET" | jq -er .access_token)"
unset PARKS_CLIENT_SECRET

curl -k -i "$PARKS_URL/jwt/ws/data/all"
curl -k -i -H "Authorization: Bearer invalid-token" "$PARKS_URL/jwt/ws/data/all"
curl -k -i -H "Authorization: Bearer $JWT_TOKEN" "$PARKS_URL/jwt/ws/data/all"
unset JWT_TOKEN
```

| Test | Expected response |
| --- | --- |
| Missing token | 401 |
| Forged/expired token or wrong `iss`/`aud` | 401 |
| Valid Keycloak JWT | 200 |
| Exceed per-client limits | 429 |
| Correct API key on original `/ws/data/all` | Existing API-key behaviour preserved |

A 403 requires a separate JWT authorisation/role policy; this module demonstrates **authentication**, not a claim-based RBAC rule.

## 6. Abuse/rate limiting and DDoS boundary

The JWT route has two independent RHCL limits:

| Limit | Burst | Sustained | Key |
| --- | --- | --- | --- |
| Per JWT client | 5 requests / 10s | 30 requests / minute | Validated `sub` claim |
| Whole JWT HTTPRoute | 100 requests / 10s | 300 requests / minute | Shared aggregate |

The aggregate route quota may intentionally affect all clients during a demo. Tune both for actual traffic, and measure p95/p99 latency. Verify a low-volume 429 demonstration with `scripts/test-jwt.sh`; do not conduct high-volume stress tests against a shared cluster.

**Production security boundary:**

1. **Internet / network DDoS:** Use upstream DDoS mitigation and, when required, WAF/CDN or enterprise edge protection (such as the customer's existing F5/Cloudflare/AWS protection), plus upstream connection/syn-flood controls. RHCL rate limits do not absorb volumetric L3/L4 attacks.
2. **Ingress protection:** Route traffic through the controlled WAF/edge; restrict bypass paths to the OpenShift Route/Gateway with network controls. Plan gateway replica/capacity, timeouts and observability.
3. **Application-layer abuse:** RHCL checks signed bearer JWTs and enforces per-client + aggregate 429 quotas on the JWT path.
4. **Identity endpoint protection:** Keep Keycloak administration restricted, set client-secret rotation and sensible token issuance/connection limits at the identity edge. `bruteForceProtected` mainly addresses interactive user login attempts, not volumetric abuse of the token endpoint.
5. **Token lifecycle:** Use short-lived signed access tokens, trusted TLS, JWKS key rotation, and unique confidential clients. A deleted Keycloak client can no longer mint new tokens, but an already issued self-contained JWT may remain valid until expiry; use introspection/short expiry if immediate revocation is required.

For Westpac's requirements, present this as **JWT validation: yes; API abuse/429: yes; comprehensive DDoS mitigation: external security control required**.

## Clean up the optional demonstration only

If you need to remove the JWT lab without touching API-key policies, inspect the targets and then explicitly remove only these three optional resources:

```bash
oc -n rhcl-parks-demo delete ratelimitpolicy parks-jwt-rate-limits
oc -n rhcl-parks-demo delete authpolicy parks-jwt-auth
oc -n rhcl-parks-demo delete httproute parks-jwt
```

Do not delete the Keycloak instance or realm if it is used by other applications.

## References

- [Red Hat Connectivity Link 1.4 — OIDC authentication](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/rhcl-oidc-authentication)
- [RHBK 26.4 — Basic Operator deployment](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/operator_guide/basic-deployment-)
- [RHBK 26.4 — Realm import](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/operator_guide/realm-import-)
- [Kuadrant — JWT authenticated rate limiting](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/user-guides/ratelimiting/authenticated-rl-with-jwt-and-k8s-authnz/)
- [OpenShift 4.22 — HTTPRoute and URLRewrite](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/configuring-gateway-api)
