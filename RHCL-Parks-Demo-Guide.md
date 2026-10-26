# RHCL 1.4.3 on OpenShift 4.22 — Parks API demo

This self-contained lab exposes a National Parks-themed API through an **OpenShift HTTPS Route -> Gateway Service -> RHCL Gateway/HTTPRoute**. It uses OpenShift's `openshift-default` GatewayClass and RHCL `AuthPolicy`/`RateLimitPolicy` APIs. It does **not** deploy the original National Parks/MongoDB application or the Parksmap user interface. The demo API uses familiar `/ws/info/` and `/ws/data/all` endpoints with four bundled sample parks.

**Status:** Wayne deployed the Parks API and OpenShift Gateway on 4.22.18 successfully. The HTTPS Route is created by a separate helper script. RHCL authentication/rate-limit enforcement still requires a Ready Kuadrant instance and cluster validation.

## 1. Check the cluster prerequisites

Log in with an account that can create cluster-scoped GatewayClass resources and namespaced RHCL policies.

```bash
oc whoami
oc get clusterversion
oc get csv -A | grep -Ei 'connectivity|kuadrant|authorino|limitador|dns-operator'
oc get kuadrant -A
oc get gatewayclass
oc get authorino,limitador -A
```

Important: An installed RHCL Operator CSV is **not** the same as a ready Kuadrant instance. If `oc get kuadrant -A` shows no instance, create one through **Ecosystem → Installed Operators → Red Hat Connectivity Link → Kuadrant → Create Kuadrant** in the namespace where the RHCL Operator is installed (typically `kuadrant-system`). Wait for Authorino and Limitador components to become ready. If the instance already exists, reuse it; do not create a duplicate.

If `openshift-default` is missing, a cluster administrator can enable OpenShift's native gateway controller:

```bash
oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF

oc get gatewayclass openshift-default -o yaml
```

Wait until `Accepted`, `ControllerInstalled`, and `CRDsReady` are True. Do not recreate or replace an existing working GatewayClass.

## 2. Deploy the API and policies

Run from the directory containing `rhcl-parks-demo.yaml`:

```bash
oc apply -f rhcl-parks-demo.yaml
oc -n rhcl-parks-demo rollout status deployment/parks-api --timeout=180s
oc -n rhcl-parks-demo get pods,svc,gateway,httproute,authpolicy,ratelimitpolicy
oc -n rhcl-parks-demo get gateway parks-gw -o yaml
oc -n rhcl-parks-demo get httproute parks-api -o yaml
oc -n rhcl-parks-demo get authpolicy parks-auth -o yaml
oc -n rhcl-parks-demo get ratelimitpolicy parks-rate-limits -o yaml
```

Confirm that Gateway is `Programmed=True`, HTTPRoute has `Accepted=True` and `ResolvedRefs=True`, and both policies have `Accepted=True` and `Enforced=True`. If one is not ready, inspect its `.status.conditions` before sending demo traffic. Policy reconciliation can take a short time.

The manifest starts with a placeholder hostname (`parks-api.example.test`). The Route helper script replaces it on the live Gateway and HTTPRoute with the cluster-assigned OpenShift Route hostname. **Rerun the helper after reapplying this manifest**, because `oc apply` can restore the placeholder.

## 3. Create and use an OpenShift HTTPS Route

Run from the cloned repository **after** the Gateway Service appears:

```bash
oc -n rhcl-parks-demo get svc
bash scripts/expose-route.sh
oc -n rhcl-parks-demo get route parks-api-gateway
```

OpenShift 4.22 created the Gateway Service as `parks-gw-openshift-default` (not `parks-gw`). The script creates an **edge-TLS Route** pointing at that Service, reads the assigned DNS host, and patches both Gateway API hostnames to match. It is idempotent and safe to rerun. There is no need to leave a port-forward process running.

**Do not create the Route directly to the `parks-api` Service**—that would skip the gateway policies. Do not run the tests as an authentication demonstration until the `AuthPolicy` and `RateLimitPolicy` report `Enforced=True`.

In your testing terminal, set:

```bash
export PARKS_URL="https://$(oc -n rhcl-parks-demo get route parks-api-gateway -o jsonpath='{.spec.host}')"
export ALICE_KEY=alice-parks-demo-key
export BOB_KEY=bob-parks-demo-key
export BENCH_KEY=benchmark-parks-demo-key
echo "$PARKS_URL"
```

The browser should also reach `$PARKS_URL/ws/info/` once authentication is configured; browsers without an API key should receive an authentication error. Your Mac reported an untrusted Route certificate, so the HTTPS curl examples below use `-k` / `--insecure`. **This skips TLS server verification and is for this controlled lab only.** For real workloads, trust the cluster CA and use `curl --cacert /path/to/ca.pem` (or install a trusted Route certificate). See [curl's TLS certificate guide](https://curl.se/docs/sslcerts.html).

These are **public example lab credentials** embedded in the YAML for convenience. Never use them for real systems or leave them exposed as a production API.

## 4. Demonstrate HTTP 200, 400, 401, and 404

### 200 — valid API request

```bash
curl -k -i -H "Authorization: APIKEY $ALICE_KEY" \
  "$PARKS_URL/ws/data/all"
```

Expected: `HTTP 200`, JSON containing four national parks.

### 400 — missing required application parameter

```bash
curl -k -i -H "Authorization: APIKEY $ALICE_KEY" \
  "$PARKS_URL/ws/data/park"
```

Expected: `HTTP 400` and `name query parameter is required`. This `400` is generated by the **Parks API** and forwarded by RHCL; it is not native RHCL OpenAPI-schema validation.

### 401 — missing API key

```bash
curl -k -i "$PARKS_URL/ws/info/"
```

Expected: unauthorized (normally `HTTP 401`). This response is enforced by RHCL/Authorino.

### 404 — nonexistent resource

```bash
curl -k -i -H "Authorization: APIKEY $ALICE_KEY" \
  "$PARKS_URL/ws/data/park?name=Atlantis"
```

Expected: `HTTP 404` from the API.

## 5. Demonstrate per-client burst and sustained limits

The deployed `RateLimitPolicy` has independent identity-based counters:

| Client | Short window | Sustained window |
| --- | ---: | ---: |
| Alice | 5 requests per 10 seconds | 15 per minute |
| Bob | 2 requests per 10 seconds | 6 per minute |
| Benchmark client | 10,000 per 10 seconds | 100,000 per minute |

### Bob: observe HTTP 429 after the second request

```bash
for i in $(seq 1 8); do
  curl -k -sS -o /dev/null -w "Bob request $i: %{http_code}\n" \
    -H "Authorization: APIKEY $BOB_KEY" \
    "$PARKS_URL/ws/data/all"
done
```

On fresh counters, expect two `200`s followed by `429`s. Alice has a separate counter, so Bob's traffic should not consume Alice's allowance.

### Alice: observe a different limit

```bash
for i in $(seq 1 8); do
  curl -k -sS -o /dev/null -w "Alice request $i: %{http_code}\n" \
    -H "Authorization: APIKEY $ALICE_KEY" \
    "$PARKS_URL/ws/data/all"
done
```

On fresh counters, expect five `200`s followed by `429`s. Earlier requests in the same window can affect the result; allow at least a minute for a clean repeat.

### Sustained window: 15/minute for Alice

After allowing old demo counters to expire (at least 65 seconds is convenient), issue three five-request bursts, separated by 11 seconds, and then a sixteenth request:

```bash
for batch in 1 2 3; do
  for i in $(seq 1 5); do
    curl -k -sS -o /dev/null -w "%{http_code} " \
        -H "Authorization: APIKEY $ALICE_KEY" \
      "$PARKS_URL/ws/info/"
  done
  echo
  sleep 11
done

curl -k -i -H "Authorization: APIKEY $ALICE_KEY" \
  "$PARKS_URL/ws/info/"
```

The sixteenth request should return `429` if it is within the one-minute counter window. This proves combined short and long windows, **not** a true token-bucket burst algorithm.

## 6. Demonstrate latency

Optionally open a direct backend port-forward **only to collect a rough baseline**. All gateway demos still use the HTTPS Route:

```bash
oc -n rhcl-parks-demo port-forward svc/parks-api 18081:8080
```

Run these commands from your testing terminal if you have the `hey` benchmark tool available:

```bash
# Backend only: no gateway or auth/rate-limit policy
hey -n 1000 -c 10 http://127.0.0.1:18081/ws/data/all

# HTTPS Route + authentication + rate checking; high-quota benchmark client
hey -n 1000 -c 10 \
  -H "Authorization: APIKEY benchmark-parks-demo-key" \
  "$PARKS_URL/ws/data/all"
```

Compare p50/p95/p99 latency, throughput and non-2xx counts. The direct backend test is a local port-forward, while the gateway test now goes through the HTTPS Route (extra router and TLS overhead); **this is not a fair isolated RHCL-overhead comparison**. For a customer SLA, benchmark both paths from a controlled equivalent network vantage point with comparable TLS and ingress layers.

## 7. OpenTelemetry tracing — required setup, not included in the base manifest

The base manifest does **not** claim that a trace backend is installed. First check:

```bash
oc api-resources | grep -Ei 'opentelemetrycollector|tempo|telemetry|istio'
oc get kuadrant -A
oc get istio -A
```

For full documented RHCL 1.4 distributed tracing, use Red Hat OpenShift Distributed Tracing Platform (Tempo/OTLP collector) and a supported OpenShift Service Mesh 3.4 instance whose Istio CR you control. OpenShift's automatically managed `openshift-default` controller does not expose the same user-editable `Istio` CR workflow. Do **not** patch the Ingress Operator's managed Istio components for this demo.

Once a supported tracing collector and independently managed Service Mesh gateway are in place, the RHCL 1.4 observability guide describes the following settings:

1. Configure an Istio `meshConfig.extensionProviders` OpenTelemetry provider, for example `tempo-otlp`, pointing at the collector on OTLP/gRPC port 4317.
2. Set an Istio `Telemetry` resource on the **gateway's namespace** with tracing provider `tempo-otlp` and a sampling percentage appropriate to the POC.
3. Configure the existing `Kuadrant` instance's `spec.observability.tracing.defaultEndpoint` to the collector (`rpc://COLLECTOR_SERVICE:4317`), with TLS validation enabled in production.
4. If you need rate-limit and authentication spans, configure the existing `Authorino` and `Limitador` instances' `spec.tracing.endpoint` fields. Preserve other existing Operator-managed fields.
5. Send a request with a unique `x-request-id`, examine gateway/policy spans in Tempo/Grafana, and instrument the Parks API if full application-level spans are required.

**Caveat:** Red Hat documents that parent trace IDs do not propagate into some WebAssembly/Limitador interactions, so correlation across all components may not be perfect. Make this an explicit POC pass/fail check.

Reference: [Red Hat Connectivity Link 1.4 Observability guide](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/observability/rhcl-observability).

## 8. WAF integration — external dependency

The base manifest does **not** deploy a WAF, because the necessary policies and connection configuration depend on your WAF vendor and on how the cluster gateway is externally exposed.

To demonstrate a real WAF, place your selected WAF (Cloudflare, F5, Akamai, AWS WAF, etc.) upstream of the Route hostname; preserve the `Host` header and original client identity; block access to alternate entry points (especially the separate AWS LoadBalancer automatically created for the Gateway); and create a temporary test rule, such as rejecting a request header `X-Demo-Block: true`.

Then verify:

1. Normal authenticated request through WAF -> Parks API `200`.
2. WAF test-rule request -> blocked **by WAF** with a corresponding WAF event.
3. Missing key through WAF -> RHCL `401`.
4. Too many valid requests through WAF -> RHCL `429`.
5. Directly reaching the gateway origin is denied externally, to prevent WAF bypass.

This is a design/test procedure, not a vendor-independent, deployable WAF policy.

## 9. Troubleshooting

```bash
oc -n rhcl-parks-demo describe route parks-api-gateway
oc -n rhcl-parks-demo describe gateway parks-gw
oc -n rhcl-parks-demo describe httproute parks-api
oc -n rhcl-parks-demo describe authpolicy parks-auth
oc -n rhcl-parks-demo describe ratelimitpolicy parks-rate-limits
oc -n rhcl-parks-demo logs deployment/parks-api --tail=100
oc get kuadrant -A
oc get pods -A | grep -Ei 'authorino|limitador|kuadrant'
```

- **404 from gateway:** rerun `bash scripts/expose-route.sh` and confirm the OpenShift Route hostname exactly matches both the Gateway listener and HTTPRoute hostname.
- **503:** confirm `parks-api` pod is Ready and Service has a healthy endpoint.
- **All requests return 401:** check `AuthPolicy` Enforced status, API key Secret labels, and authorization header `APIKEY` prefix.
- **Rate limits never trigger:** verify `RateLimitPolicy` Enforced status and the identity mapping in `AuthPolicy` before testing.
- **Gateway has no Service:** verify GatewayClass Accepted/ControllerInstalled and Gateway Programmed status; on this cluster the generated Service is `parks-gw-openshift-default`, not `parks-gw`.

## 10. Cleanup (optional)

This demo uses an isolated namespace. Only if you choose to remove it:

```bash
oc delete namespace rhcl-parks-demo
```

Do **not** delete the cluster's shared `openshift-default` GatewayClass or an existing `Kuadrant` instance; those may serve other workloads.

## Official references

- [RHCL 1.4: Connect and secure APIs and services](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/connect-secure-apis-services)
- [RHCL 1.4: About Connectivity Link and supported configurations](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/red_hat_connectivity_link/rhcl-introduction)
- [OCP 4.22: Configuring Gateway API](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/configuring-gateway-api)
- [OpenShift National Parks backend workshop](https://redhat-scholars.github.io/openshift-starter-guides/rhs-openshift-starter-guides/4.21/nationalparks.html)
