#!/usr/bin/env bash
# Read-only RHCL Parks API validation. Sends small, controlled HTTP requests.
# Does NOT apply/delete Kubernetes resources, reveal secrets, or generate attack traffic.
set -uo pipefail
set +x
trap 'unset KC_CLIENT_SECRET PARKS_CONSUMER_API_KEY access_token token_json 2>/dev/null || true' EXIT

NS="${RHCL_NS:-rhcl-parks-demo}"
CONSUMER_NS="${RHCL_CONSUMER_NS:-rhcl-parks-consumer}"
CONSUMER_NAME="${PARKS_CONSUMER_KEY_NAME:-test-key}"
ALICE_KEY="${ALICE_KEY:-alice-parks-demo-key}"
BOB_KEY="${BOB_KEY:-bob-parks-demo-key}"
BENCH_KEY="${BENCH_KEY:-benchmark-parks-demo-key}"
PARKS_URL="${PARKS_URL:-}"
KC_URL="${KC_URL:-}"
KC_CLIENT_SECRET="${KC_CLIENT_SECRET:-}"
PARKS_CONSUMER_API_KEY="${PARKS_CONSUMER_API_KEY:-}"
VERIFY_TLS="${VERIFY_TLS:-0}"

QUICK=0
INTERACTIVE=1
PERFORMANCE=1
PASS=0
FAIL=0
SKIP=0
CURL_TLS=()

usage() {
  printf '%s\n' \
    'Usage: bash scripts/test-all.sh [--quick] [--non-interactive] [--no-perf]' \
    '' \
    'Default (~3-4 min): tests routing, policies, status codes and active API plans,' \
    'or (when active) Alice/Bob limits, API Products/approval, JWT and 20' \
    'small latency probes. Does NOT modify cluster resources or test volumetric DDoS.' \
    '' \
    '  --quick            Skip 65s sustained-quota and JWT-expiry wait tests' \
    '  --non-interactive  Do not prompt for API product key / Keycloak client secret' \
    '  --no-perf          Skip the 20-request latency smoke test' \
    '' \
    'Optional environment inputs:' \
    '  RHCL_NS, RHCL_CONSUMER_NS, PARKS_CONSUMER_KEY_NAME' \
    '  PARKS_URL, KC_URL, PARKS_CONSUMER_API_KEY, KC_CLIENT_SECRET' \
    '  VERIFY_TLS=1      Verify HTTPS certificates (default skips TLS for lab only)'
}

for opt in "$@"; do
  case "$opt" in
    --quick) QUICK=1 ;;
    --non-interactive) INTERACTIVE=0 ;;
    --no-perf) PERFORMANCE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$opt" >&2; usage >&2; exit 2 ;;
  esac
done

pass() { PASS=$((PASS+1)); printf 'PASS  %-26s %s\n' "$1" "${2:-}"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %-26s %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP  %-26s %s\n' "$1" "${2:-}"; }
section() { printf '\n=== %s ===\n' "$1"; }

for bin in oc curl jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'ERROR: %s is required.\n' "$bin" >&2
    exit 2
  fi
done

if [[ "$VERIFY_TLS" != "1" ]]; then
  CURL_TLS=(-k)
  printf '%s\n' 'NOTE: TLS server verification disabled for this sandbox (-k).'
fi

http_code() {
  local url="$1"
  shift
  local result
  if result="$(curl "${CURL_TLS[@]}" -sS --connect-timeout 4 --max-time 12 \
    -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null)"; then
    printf '%s\n' "$result"
  else
    printf '000\n'
  fi
}

expect_code() {
  local title="$1" expected="$2" url="$3"
  shift 3
  local actual
  actual="$(http_code "$url" "$@")"
  if [[ "$actual" == "$expected" ]]; then
    pass "$title" "HTTP $actual"
    return 0
  else
    fail "$title" "expected $expected, got $actual"
    return 1
  fi
}

policy_status() {
  local resource="$1" name="$2" label="$3" payload accepted enforced details
  if ! payload="$(oc -n "$NS" get "$resource" "$name" -o json 2>/dev/null)"; then
    fail "$label" "$resource/$name missing"
    return 1
  fi
  accepted="$(printf '%s' "$payload" | jq -r '[.status.conditions[]? | select(.type=="Accepted") | .status] | last // "Unknown"')"
  enforced="$(printf '%s' "$payload" | jq -r '[.status.conditions[]? | select(.type=="Enforced") | .status] | last // "Unknown"')"
  details="$(printf '%s' "$payload" | jq -r '[.status.conditions[]? | select(.type=="Enforced") | .message] | last // ""')"
  if [[ "$accepted" == "True" && "$enforced" == "True" ]]; then
    pass "$label" 'Accepted=True, Enforced=True'
    return 0
  fi
  fail "$label" "Accepted=$accepted Enforced=$enforced; $details"
  return 1
}

section 'Prerequisites, Gateway, and policies'
if current_user="$(oc whoami 2>/dev/null)" && [[ -n "$current_user" ]]; then
  pass 'OpenShift login' "$current_user"
else
  fail 'OpenShift login' 'oc login to the correct cluster first'
  exit 2
fi

version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
printf 'Cluster version: %s\n' "${version:-unknown}"

if [[ -z "$PARKS_URL" ]]; then
  host="$(oc -n "$NS" get route parks-api-gateway -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$host" ]] && PARKS_URL="https://$host"
fi

if [[ -n "$PARKS_URL" ]]; then
  pass 'Parks HTTPS Route' "$PARKS_URL"
else
  fail 'Parks HTTPS Route' 'parks-api-gateway Route has no hostname'
  exit 2
fi

target="$(oc -n "$NS" get route parks-api-gateway -o jsonpath='{.spec.to.name}' 2>/dev/null || true)"
if [[ "$target" == 'parks-gw-openshift-default' ]]; then
  pass 'Route target' "$target (gateway, not app)"
else
  fail 'Route target' "expected parks-gw-openshift-default, got ${target:-missing}"
fi

gateway_json="$(oc -n "$NS" get gateway parks-gw -o json 2>/dev/null || true)"
if [[ -n "$gateway_json" ]] && printf '%s' "$gateway_json" | jq -e \
  '.status.conditions[]? | select(.type=="Programmed" and .status=="True")' >/dev/null 2>&1; then
  pass 'Gateway' 'Programmed=True'
else
  fail 'Gateway' 'parks-gw not Programmed=True'
fi

route_json="$(oc -n "$NS" get httproute parks-api -o json 2>/dev/null || true)"
if [[ -n "$route_json" ]] && printf '%s' "$route_json" | jq -e \
  '.status.parents[]?.conditions[]? | select(.type=="Accepted" and .status=="True")' >/dev/null 2>&1; then
  pass 'Parks HTTPRoute' 'Accepted=True'
else
  fail 'Parks HTTPRoute' 'route not accepted'
fi

auth_ok=0
rl_ok=0
plan_ok=0
if policy_status authpolicy parks-auth 'API-key AuthPolicy'; then auth_ok=1; fi

# A PlanPolicy on the same HTTPRoute intentionally overrides its RateLimitPolicy.
# Only recognise that as healthy when BOTH the override and the active PlanPolicy
# have the expected status and target; a missing/broken policy remains a FAIL.
rl_json="$(oc -n "$NS" get ratelimitpolicy parks-rate-limits -o json 2>/dev/null || true)"
if [[ -z "$rl_json" ]]; then
  fail 'API-key rate policy' 'parks-rate-limits missing'
else
  rl_accepted="$(printf '%s' "$rl_json" | jq -r '[.status.conditions[]? | select(.type=="Accepted") | .status] | last // "Unknown"')"
  rl_enforced="$(printf '%s' "$rl_json" | jq -r '[.status.conditions[]? | select(.type=="Enforced") | .status] | last // "Unknown"')"
  rl_reason="$(printf '%s' "$rl_json" | jq -r '[.status.conditions[]? | select(.type=="Enforced") | .reason] | last // ""')"
  rl_message="$(printf '%s' "$rl_json" | jq -r '[.status.conditions[]? | select(.type=="Enforced") | .message] | last // ""')"
  if [[ "$rl_accepted" == 'True' && "$rl_enforced" == 'True' ]]; then
    pass 'API-key RateLimitPolicy' 'Accepted=True, Enforced=True (Alice/Bob limits)'
    rl_ok=1
  elif [[ "$rl_accepted" == 'True' && "$rl_enforced" == 'False' &&
          "$rl_reason" == 'Overridden' && "$rl_message" == *"parks-plans"* ]]; then
    plan_json="$(oc -n "$NS" get planpolicy parks-plans -o json 2>/dev/null || true)"
    if [[ -z "$plan_json" ]]; then
      fail 'API-key PlanPolicy' 'parks-rate-limits overridden, but parks-plans missing'
    else
      plan_accepted="$(printf '%s' "$plan_json" | jq -r '[.status.conditions[]? | select(.type=="Accepted") | .status] | last // "Unknown"')"
      plan_enforced="$(printf '%s' "$plan_json" | jq -r '[.status.conditions[]? | select(.type=="Enforced") | .status] | last // "Unknown"')"
      plan_target="$(printf '%s' "$plan_json" | jq -r '.spec.targetRef.kind // ""')/$(printf '%s' "$plan_json" | jq -r '.spec.targetRef.name // ""')"
      plan_tiers="$(printf '%s' "$plan_json" | jq -r '[.spec.plans[]? | select(.tier != null and .limits.daily != null) | "\(.tier)=\(.limits.daily)/day"] | join(", ")')"
      if [[ "$plan_accepted" == 'True' && "$plan_enforced" == 'True' &&
            "$plan_target" == 'HTTPRoute/parks-api' && -n "$plan_tiers" ]]; then
        skip 'API-key RateLimitPolicy' 'overridden by active parks-plans (expected)'
        pass 'API-key PlanPolicy' "Accepted=True, Enforced=True; $plan_tiers (configuration, not 429 proof)"
        plan_ok=1
      else
        fail 'API-key PlanPolicy' "Accepted=$plan_accepted Enforced=$plan_enforced Target=$plan_target Tiers=${plan_tiers:-none}"
      fi
    fi
  else
    fail 'API-key RateLimitPolicy' "Accepted=$rl_accepted Enforced=$rl_enforced Reason=${rl_reason:-unknown}; $rl_message"
  fi
fi

section 'HTTP status codes'
api_ok=0
if expect_code '200: valid API key' 200 "$PARKS_URL/ws/data/all" \
  -H "Authorization: APIKEY $ALICE_KEY"; then
  api_ok=1
fi
expect_code '400: missing name' 400 "$PARKS_URL/ws/data/park" \
  -H "Authorization: APIKEY $ALICE_KEY"
expect_code '401: missing API key' 401 "$PARKS_URL/ws/info/"
expect_code '404: unknown park' 404 "$PARKS_URL/ws/data/park?name=Atlantis" \
  -H "Authorization: APIKEY $ALICE_KEY"

burst_test() {
  local label="$1" key="$2" ok200=0 ok429=0 other=0 code i
  for i in {1..8}; do
    code="$(http_code "$PARKS_URL/ws/data/all" -H "Authorization: APIKEY $key")"
    printf '  %s request %s: %s\n' "$label" "$i" "$code"
    case "$code" in
      200) ok200=$((ok200+1)) ;;
      429) ok429=$((ok429+1)) ;;
      *) other=$((other+1)) ;;
    esac
  done
  if (( ok200 > 0 && ok429 > 0 && other == 0 )); then
    pass "$label burst" "$ok200 x 200, $ok429 x 429"
  else
    fail "$label burst" "$ok200 x 200, $ok429 x 429, $other unexpected; check counter state"
  fi
}

section 'Client rate limiting'
if [[ "$rl_ok" -eq 1 && "$auth_ok" -eq 1 && "$api_ok" -eq 1 ]]; then
  burst_test Bob "$BOB_KEY"
  burst_test Alice "$ALICE_KEY"

  if [[ "$QUICK" -eq 1 ]]; then
    skip 'Alice sustained 15/min' 'skipped by --quick'
  else
    printf '%s\n' 'Waiting 65 seconds to clear previous rate-limit windows...'
    sleep 65
    sustained200=0
    sustained_other=0
    for batch in 1 2 3; do
      for i in {1..5}; do
        code="$(http_code "$PARKS_URL/ws/info/" -H "Authorization: APIKEY $ALICE_KEY")"
        printf '  sustained batch %s request %s: %s\n' "$batch" "$i" "$code"
        if [[ "$code" == 200 ]]; then
          sustained200=$((sustained200+1))
        else
          sustained_other=$((sustained_other+1))
        fi
      done
      if [[ "$batch" -lt 3 ]]; then sleep 11; fi
    done
    sixteenth="$(http_code "$PARKS_URL/ws/info/" -H "Authorization: APIKEY $ALICE_KEY")"
    if [[ "$sustained200" -eq 15 && "$sustained_other" -eq 0 && "$sixteenth" == 429 ]]; then
      pass 'Alice sustained 15/min' '15 x 200 then 16th x 429'
    else
      fail 'Alice sustained 15/min' "15 calls: $sustained200 x 200, $sustained_other other; 16th=$sixteenth"
    fi
  fi
elif [[ "$plan_ok" -eq 1 && "$auth_ok" -eq 1 && "$api_ok" -eq 1 ]]; then
  skip 'Bob burst 429' 'parks-plans overrides Alice/Bob short-window quotas'
  skip 'Alice burst 429' 'parks-plans overrides Alice/Bob short-window quotas'
  skip 'Alice sustained 15/min' 'parks-plans enforces daily tiers instead'
  skip 'Plan daily 429' 'would consume a shared daily tier quota; not part of safe smoke test'
else
  skip 'Bob burst 429' 'API unavailable or active rate policy not enforced'
  skip 'Alice burst 429' 'API unavailable or active rate policy not enforced'
  skip 'Alice sustained 15/min' 'needs parks-rate-limits Enforced=True'
fi

section 'API Product and API Key approval'
if ! oc api-resources --api-group=devportal.kuadrant.io 2>/dev/null | grep -q '^apiproducts'; then
  skip 'API management CRDs' 'API Product/API Key CRDs are missing'
  skip 'API Product' 'cannot inspect a product without CRDs'
  skip 'Consumer API Key' 'cannot inspect APIKey resources'
else
  pass 'API management CRDs' 'devportal.kuadrant.io available'

  product_json="$(oc -n "$NS" get apiproduct national-parks-api -o json 2>/dev/null || true)"
  if [[ -z "$product_json" ]]; then
    skip 'API Product' 'national-parks-api not deployed'
  else
    published="$(printf '%s' "$product_json" | jq -r '.spec.publishStatus // ""')"
    ready="$(printf '%s' "$product_json" | jq -r '[.status.conditions[]? | select(.type=="Ready") | .status] | last // "Unknown"')"
    if [[ "$published" == 'Published' && "$ready" == 'True' ]]; then
      pass 'API Product' 'Published; Ready=True'
    else
      fail 'API Product' "publishStatus=$published, Ready=$ready"
    fi
    docs_url="$(printf '%s' "$product_json" | jq -r '.spec.documentation.docsURL // ""')"
    if [[ "$docs_url" == *'/blob/main/README.md' ]]; then
      pass 'Product documentation' 'points to current README'
    else
      fail 'Product documentation' 'outdated docsURL; update using docs/api-product.yaml'
    fi
  fi

  consumer_json="$(oc -n "$CONSUMER_NS" get apikey "$CONSUMER_NAME" -o json 2>/dev/null || true)"
  if [[ -z "$consumer_json" ]]; then
    skip 'Consumer API Key' "$CONSUMER_NS/$CONSUMER_NAME not found (set PARKS_CONSUMER_KEY_NAME)"
  else
    approval="$(printf '%s' "$consumer_json" | jq -r '[.status.conditions[]? | select(.type=="Approved") | .status] | last // "Unknown"')"
    if [[ "$approval" != 'True' ]]; then
      fail 'Consumer API Key' "Approved=$approval; approve via Connectivity Link API Catalog"
    else
      pass 'Consumer API Key' 'Approved=True'
      if [[ -z "$PARKS_CONSUMER_API_KEY" && "$INTERACTIVE" -eq 1 && -t 0 ]]; then
        printf 'Paste the APPROVED consumer API key (Enter to skip): '
        IFS= read -r -s PARKS_CONSUMER_API_KEY || true
        printf '\n'
      fi
      if [[ -z "$PARKS_CONSUMER_API_KEY" ]]; then
        skip 'Consumer key HTTP' 'approved, but key value not provided'
      else
        expect_code 'Consumer key HTTP' 200 "$PARKS_URL/ws/data/all" \
          -H "Authorization: APIKEY $PARKS_CONSUMER_API_KEY"
      fi
    fi
  fi
fi

section 'Keycloak and JWT'
jwt_auth_ok=0
jwt_rl_ok=0
if policy_status authpolicy parks-jwt-auth 'JWT AuthPolicy'; then jwt_auth_ok=1; fi
if policy_status ratelimitpolicy parks-jwt-rate-limits 'JWT RateLimitPolicy'; then jwt_rl_ok=1; fi

if [[ -z "$KC_URL" ]]; then
  keycloak_host="$(oc -n "$NS" get route parks-keycloak -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$keycloak_host" ]] && KC_URL="https://$keycloak_host"
fi

if [[ -z "$KC_URL" ]]; then
  skip 'Keycloak Route' 'parks-keycloak not found'
  skip 'JWT token issuance' 'no Keycloak URL'
  skip 'JWT HTTP tests' 'requires Keycloak and JWT policies'
else
  pass 'Keycloak Route' "$KC_URL"

  if [[ "$jwt_auth_ok" -eq 1 ]]; then
    expect_code 'JWT without token' 401 "$PARKS_URL/jwt/ws/data/all"
    expect_code 'JWT wrong auth scheme' 401 "$PARKS_URL/jwt/ws/data/all" \
      -H "Authorization: APIKEY $ALICE_KEY"
  else
    skip 'JWT negative HTTP' 'JWT AuthPolicy not enforced'
  fi

  if [[ -z "$KC_CLIENT_SECRET" && "$INTERACTIVE" -eq 1 && -t 0 ]]; then
    printf 'Paste CURRENT parks-demo-client secret (Enter to skip): '
    IFS= read -r -s KC_CLIENT_SECRET || true
    printf '\n'
  fi

  if [[ -z "$KC_CLIENT_SECRET" ]]; then
    skip 'JWT token issuance' 'client secret not provided'
    skip 'JWT valid 200' 'no token'
    skip 'JWT per-subject 429' 'no token'
    skip 'JWT expired 401' 'no token'
  else
    token_json=''
    if token_json="$(curl "${CURL_TLS[@]}" -sS --connect-timeout 8 --max-time 25 \
      -X POST "$KC_URL/realms/parks/protocol/openid-connect/token" \
      -d grant_type=client_credentials \
      -d client_id=parks-demo-client \
      --data-urlencode "client_secret=$KC_CLIENT_SECRET" 2>/dev/null)"; then
      access_token="$(printf '%s' "$token_json" | jq -r '.access_token // empty' 2>/dev/null)"
      expires="$(printf '%s' "$token_json" | jq -r '.expires_in // empty' 2>/dev/null)"
      token_error="$(printf '%s' "$token_json" | jq -r '.error // empty' 2>/dev/null)"
      unset KC_CLIENT_SECRET token_json

      if [[ -z "$access_token" ]]; then
        fail 'JWT token issuance' "Keycloak refused client_credentials: ${token_error:-unknown error}. Verify Client auth, Service accounts, Credentials."
        skip 'JWT valid 200' 'no token'
        skip 'JWT per-subject 429' 'no token'
        skip 'JWT expired 401' 'no token'
      else
        pass 'JWT token issuance' "Bearer access token received (expires_in=${expires:-unknown}s)"

        if [[ "$jwt_auth_ok" -eq 1 && "$jwt_rl_ok" -eq 1 ]]; then
          expect_code 'JWT valid 200' 200 "$PARKS_URL/jwt/ws/data/all" \
            -H "Authorization: Bearer $access_token"

          jwt_200=0
          jwt_429=0
          jwt_other=0
          for i in {1..8}; do
            result="$(http_code "$PARKS_URL/jwt/ws/data/all" \
              -H "Authorization: Bearer $access_token")"
            printf '  JWT request %s: %s\n' "$i" "$result"
            case "$result" in
              200) jwt_200=$((jwt_200+1)) ;;
              429) jwt_429=$((jwt_429+1)) ;;
              *) jwt_other=$((jwt_other+1)) ;;
            esac
          done
          if (( jwt_200 > 0 && jwt_429 > 0 && jwt_other == 0 )); then
            pass 'JWT per-subject 429' "$jwt_200 x 200, $jwt_429 x 429"
          else
            fail 'JWT per-subject 429' "$jwt_200 x 200, $jwt_429 x 429, $jwt_other other"
          fi

          if [[ "$QUICK" -eq 1 ]]; then
            skip 'JWT expired 401' 'skipped by --quick'
          elif [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > 0 && expires <= 300 )); then
            wait_seconds=$((expires+5))
            printf 'Waiting %s seconds to check token expiration...\n' "$wait_seconds"
            sleep "$wait_seconds"
            expect_code 'JWT expired 401' 401 "$PARKS_URL/jwt/ws/data/all" \
              -H "Authorization: Bearer $access_token"
          else
            skip 'JWT expired 401' 'unknown or long expiry; inspect token configuration'
          fi
        else
          skip 'JWT valid 200' 'JWT AuthPolicy/RateLimitPolicy not enforced'
          skip 'JWT per-subject 429' 'JWT AuthPolicy/RateLimitPolicy not enforced'
          skip 'JWT expired 401' 'JWT AuthPolicy/RateLimitPolicy not enforced'
        fi
        unset access_token
      fi
    else
      unset KC_CLIENT_SECRET
      fail 'JWT token issuance' 'Keycloak token Route unreachable'
      skip 'JWT valid 200' 'no token'
      skip 'JWT per-subject 429' 'no token'
      skip 'JWT expired 401' 'no token'
    fi
  fi
fi

skip 'Malformed JWT negative test' 'RHCL 1.4.3 WASM-shim 504 defect; test intentionally omitted'

section 'End-to-end latency smoke test'
if [[ "$PERFORMANCE" -eq 0 ]]; then
  skip 'Latency p50/p95/p99' 'skipped by --no-perf'
elif [[ "$api_ok" -ne 1 ]]; then
  skip 'Latency p50/p95/p99' 'API not reachable; no benchmark attempted'
else
  latency_values=()
  perf_errors=0
  for i in {1..20}; do
    measurement="$(curl "${CURL_TLS[@]}" -sS --connect-timeout 8 --max-time 20 \
      -o /dev/null -w '%{http_code} %{time_total}' \
      -H "Authorization: APIKEY $BENCH_KEY" \
      "$PARKS_URL/ws/data/all" 2>/dev/null || true)"
    status="${measurement%% *}"
    elapsed="${measurement#* }"
    if [[ "$status" == 200 && "$elapsed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      latency_values+=("$elapsed")
    else
      perf_errors=$((perf_errors+1))
      break
    fi
  done
  if (( ${#latency_values[@]} == 20 && perf_errors == 0 )); then
    percentile_text="$(printf '%s\n' "${latency_values[@]}" | sort -n | awk \
      '{a[NR]=$1} END{printf "p50=%.1fms p95=%.1fms p99=%.1fms",a[10]*1000,a[19]*1000,a[20]*1000}')"
    pass 'Latency p50/p95/p99' "$percentile_text (20 samples, not a load-test SLA)"
  else
    fail 'Latency p50/p95/p99' "only ${#latency_values[@]} successful; $perf_errors failed (stopped early)"
  fi
fi

section 'External integrations'
skip 'OpenTelemetry traces' 'requires collector/backend plus trace lookup; not provisioned here'
skip 'WAF/DDoS' 'needs upstream WAF, origin isolation and AWS Shield; never simulate volumetric attack'

section 'FINAL RESULTS'
printf 'PASS=%s  FAIL=%s  SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
printf '%s\n' 'SKIP means a prerequisite, credential or optional external integration is absent.'
printf '%s\n' 'No cluster resources were changed. No secrets or bearer tokens were printed.'
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
