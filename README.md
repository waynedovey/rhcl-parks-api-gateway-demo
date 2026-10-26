# Red Hat Connectivity Link — National Parks API Gateway Demo

Demonstrate API gateway capabilities using **RHCL 1.4.3** on **OpenShift 4.22.18** and a small, self-contained Parks API.

**Use an OpenShift HTTPS Route**: no local port-forwarding or custom DNS records needed to run the gateway demos.

## What this lab demonstrates

| Requirement | Demo | Expected result |
| --- | --- | --- |
| HTTP status codes | Valid request, missing parameter, missing API key, unknown park | 200, 400, 401, 404 |
| Per-client burst limits | Bob: 2 requests per 10s; Alice: 5 per 10s | 429 after allowance |
| Per-client sustained limits | Bob: 6/min; Alice: 15/min | 429 after allowance |
| OTel tracing | Optional observability stack setup | Trace gateway/policy requests (not preconfigured) |
| Performance | Benchmark the HTTPS Route | p50/p95/p99; extra baseline steps in advanced guide |
| WAF integration | Optional upstream WAF | WAF block + RHCL 401/429 (not preconfigured) |
| JWT validation (optional module) | Keycloak-issued JWT, issuer/JWKS/audience validation | 401 invalid; 200 valid |
| JWT API abuse limits (optional module) | Per-token subject + aggregate quotas | 429 when over quota; not volumetric DDoS protection |

## Architecture

```text
Client --HTTPS--> OpenShift Route (edge TLS)
                    |
                    v
              Gateway Service
              parks-gw-openshift-default
                    |
                    v
              Gateway + HTTPRoute
              (RHCL AuthPolicy / RateLimitPolicy)
                    |
                    v
                parks-api Service
                    |
                    v
                Parks API Pod
```

**Important:** The Route must point to the **Gateway Service**, not directly to `parks-api`. Sending traffic straight to the application would bypass RHCL policy enforcement.

This is a small Parks-themed API with `/ws/info/` and `/ws/data/all` endpoints; it does not require MongoDB or include the original Parksmap UI.

## 1. Check prerequisites

```bash
oc whoami
oc get clusterversion
oc get csv -A | grep rhcl-operator
oc get kuadrant -A
oc get authorino,limitador -A
oc get gatewayclass openshift-default
```

You need:

- A working OpenShift cluster and `oc` login.
- The RHCL Operator **and a Ready `Kuadrant` instance** with Authorino and Limitador. The Operator alone is insufficient.
- OpenShift's native `openshift-default` GatewayClass, with `Accepted=True`.

**Missing Kuadrant?** Create it in the **same namespace where the RHCL Operator is installed**. On Wayne's cluster that namespace is **`openshift-operators`** (verify using `oc get deployments -A | grep kuadrant-operator`). In the console: **Ecosystem → Installed Operators → Red Hat Connectivity Link → Kuadrant → Create Kuadrant**. Or use:

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

Replace `openshift-operators` if your Operator lives in another namespace. If the policies still say `MissingDependency` after creating Kuadrant and the native GatewayClass is ready, restart the discovered Operator Deployment using `oc -n openshift-operators rollout restart deployment/kuadrant-operator-controller-manager`. Reuse a healthy existing Kuadrant instance—do not create duplicates.

**Missing GatewayClass?** An administrator can enable OpenShift's built-in controller:

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

## 2. Deploy the sample API and RHCL policies

Clone the repository, then:

```bash
oc apply -f rhcl-parks-demo.yaml
oc -n rhcl-parks-demo rollout status deployment/parks-api --timeout=180s
oc -n rhcl-parks-demo get gateway,httproute,pods,svc,authpolicy,ratelimitpolicy
```

The gateway should reach `Programmed=True`. The native Gateway controller generates a Service called `parks-gw-openshift-default` in this OpenShift 4.22 setup.

## 3. Create the HTTPS Route

Run **after** the Gateway is created:

```bash
bash scripts/expose-route.sh
```

The script:

1. Creates an edge-TLS OpenShift Route pointing at `parks-gw-openshift-default:80`.
2. Reads the Route's assigned `apps.` hostname.
3. Updates the Gateway listener and HTTPRoute hostnames to match it, avoiding an Envoy `404`.
4. Prints the final HTTPS URL.

The command is safe to rerun; **rerun it after every `oc apply -f rhcl-parks-demo.yaml`**, because that file contains the original placeholder hostname.

Get the URL:

```bash
export PARKS_URL="https://$(oc -n rhcl-parks-demo get route parks-api-gateway -o jsonpath='{.spec.host}')"
echo "$PARKS_URL"
oc -n rhcl-parks-demo get route parks-api-gateway
```

**TLS note:** The commands below intentionally use `curl -k` (equivalent to `--insecure`) because this lab's OpenShift Route currently presents a certificate that your Mac does not trust. This bypasses server-certificate verification: **use it only for this controlled demo**, never in production. For proper verification, install a trusted Route certificate or use `curl --cacert /path/to/ca.pem` with your cluster CA. See [curl's TLS documentation](https://curl.se/docs/sslcerts.html).

**Check RHCL policy readiness before treating the endpoint as protected:**

```bash
oc -n rhcl-parks-demo describe authpolicy parks-auth
oc -n rhcl-parks-demo describe ratelimitpolicy parks-rate-limits
```

Both policies should show `Accepted=True` and `Enforced=True`. If `oc get kuadrant -A` reports no resources, the policy demo will **not** work just because the Route serves traffic.

## 4. Demo HTTP status codes

```bash
# 200 — list parks
curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' "$PARKS_URL/ws/data/all"

# 400 — required name query parameter is missing
curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' "$PARKS_URL/ws/data/park"

# 401 — no API key; requires enforced AuthPolicy
curl -k -i "$PARKS_URL/ws/info/"

# 404 — park not found
curl -k -i -H 'Authorization: APIKEY alice-parks-demo-key' "$PARKS_URL/ws/data/park?name=Atlantis"
```

The `400` and `404` are application responses forwarded by the gateway. The `401` is generated by the authentication layer when the policy is enforced.

## 5. Demo per-client rate limiting (HTTP 429)

Bob allows **2 requests per 10 seconds** and **6 per minute**. Run eight requests immediately:

```bash
for i in {1..8}; do
  curl -k -s -o /dev/null -w "Request $i: %{http_code}\n" \
    -H 'Authorization: APIKEY bob-parks-demo-key' \
    "$PARKS_URL/ws/data/all"
done
```

With fresh counters and working policies, expect two `200` responses followed by `429` responses. Alice has separate limits of **5/10s** and **15/min**. Allow at least a minute between repeat demonstrations.

See the [advanced guide](RHCL-Parks-Demo-Guide.md#5-demonstrate-per-client-burst-and-sustained-limits) for an explicit sustained-window test.

## 6. Demo latency

With `hey` installed, benchmark through the same Route:

```bash
hey -n 1000 -c 10 \
  -H 'Authorization: APIKEY benchmark-parks-demo-key' \
  "$PARKS_URL/ws/data/all"
```

The benchmark key has a high allowance so that `429` doesn't skew the results. Record requests/sec, p50, p95 and p99.

The Route adds an OpenShift HAProxy ingress hop and TLS termination, so this is **end-to-end Route performance**, not an isolated RHCL overhead measurement. **Note:** the `hey` benchmark does not use curl flags; if its TLS verification fails, configure the benchmark tool to trust the Route certificate before measuring. The [advanced guide](RHCL-Parks-Demo-Guide.md#6-demonstrate-latency) explains an optional backend baseline.

## 7. Optional OTel tracing and WAF

- **OpenTelemetry:** requires a deployed collector/tracing backend and separately configured supported tracing integration. The base manifest does not deliver end-to-end traces automatically.
- **WAF:** requires an external product and policy (for example Cloudflare, F5 or AWS WAF). A WAF in front of the Route must also prevent bypass through the automatically created AWS Gateway LoadBalancer.

See the [advanced guide](RHCL-Parks-Demo-Guide.md#7-opentelemetry-tracing--required-setup-not-included-in-the-base-manifest) for the configuration prerequisites and [WAF checks](RHCL-Parks-Demo-Guide.md#8-waf-integration--external-dependency).

## 8. API Products and API Keys (Technology Preview)

Publish the existing Parks `HTTPRoute` as an **API Product**, let a consumer **request an API key**, demonstrate **manual approval**, then call the HTTPS Route with the approved key.

- [Full API Products and API Keys lab](docs/API-Products-and-API-Keys.md)
- [Example APIProduct manifest](docs/api-product.yaml)
- [OpenAPI definition](docs/openapi.yaml)

First check the underlying policy state:

```bash
bash scripts/check-policies.sh
```

If either policy is `Invalid / Not Accepted`, resolve its `.status.conditions[].message` before demonstrating products or credentials. API management in RHCL 1.4 is **Technology Preview**.

## Troubleshooting

```bash
oc -n rhcl-parks-demo get route parks-api-gateway -o yaml
oc -n rhcl-parks-demo get gateway parks-gw -o yaml
oc -n rhcl-parks-demo get httproute parks-api -o yaml
oc -n rhcl-parks-demo describe authpolicy parks-auth
oc -n rhcl-parks-demo describe ratelimitpolicy parks-rate-limits
oc get kuadrant -A
bash scripts/check-policies.sh
```

- **404**: check that Route, Gateway and HTTPRoute hostnames are identical; rerun `bash scripts/expose-route.sh`.
- **503**: check Gateway `Programmed=True`, Service endpoints and Parks API readiness.
- **200 without an API key**: RHCL authentication is not enforced; stop the security demo and inspect Kuadrant/Authorino.
- **No 429**: check `RateLimitPolicy Enforced=True` and identity mapping.
- **TLS error**: check the router certificate; `curl -k` is an option for this non-production lab.
- **Route admitted but no access**: verify ingress availability/DNS and `oc -n rhcl-parks-demo describe route parks-api-gateway`.

**Security:** The credentials in the manifest are public example keys. The new Route terminates HTTPS at the OpenShift router but uses HTTP from that router to the Gateway. The Gateway also provisions a separate AWS LoadBalancer. Do not treat this lab as production-secure, and do not expose real data until policies are enforced.

## Cleanup (when finished)

```bash
oc delete namespace rhcl-parks-demo
```

Do not delete the shared GatewayClass or Kuadrant instance.

## Files

- [rhcl-parks-demo.yaml](rhcl-parks-demo.yaml): API, Gateway, HTTPRoute and policies.
- [scripts/expose-route.sh](scripts/expose-route.sh): create the Route and align hostnames.
- [scripts/check-policies.sh](scripts/check-policies.sh): read-only RHCL policy troubleshooting.
- [RHCL-Parks-Demo-Guide.md](RHCL-Parks-Demo-Guide.md): advanced per-client limit, tracing, performance and WAF guidance.
- [docs/API-Products-and-API-Keys.md](docs/API-Products-and-API-Keys.md): API discovery, product publishing, API key request/approval.
- [docs/Keycloak-JWT-and-DDoS.md](docs/Keycloak-JWT-and-DDoS.md): optional Keycloak setup, JWT verification, and API abuse / DDoS security boundary.
- [scripts/deploy-jwt.sh](scripts/deploy-jwt.sh) and [scripts/test-jwt.sh](scripts/test-jwt.sh): opt-in JWT deployment and safe 401/200/429 smoke tests.
- [docs/api-product.yaml](docs/api-product.yaml) and [docs/openapi.yaml](docs/openapi.yaml): Technology Preview APIProduct sample and OpenAPI description.

## Official documentation

- [RHCL 1.4 installation](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/install_connectivity_link/rhcl-install-on-ocp)
- [RHCL 1.4 policy examples](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/connect-secure-apis-services)
- [OpenShift 4.22 Routes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/routes)
- [OpenShift 4.22 Gateway API](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/configuring-gateway-api)
