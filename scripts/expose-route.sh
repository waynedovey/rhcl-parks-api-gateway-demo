#!/usr/bin/env bash
# Create an OpenShift HTTPS Route in front of the generated Gateway Service.
# Safe to rerun after oc apply -f rhcl-parks-demo.yaml.
set -euo pipefail

NS="rhcl-parks-demo"
GW_SERVICE="parks-gw-openshift-default"
ROUTE="parks-api-gateway"

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: oc CLI is required." >&2
  exit 1
fi

oc -n "$NS" get gateway parks-gw >/dev/null
oc -n "$NS" get service "$GW_SERVICE" >/dev/null

if ! oc -n "$NS" get route "$ROUTE" >/dev/null 2>&1; then
  oc -n "$NS" create route edge "$ROUTE" \
    --service="$GW_SERVICE" \
    --port=80 \
    --insecure-policy=Redirect
fi

actual_service=$(oc -n "$NS" get route "$ROUTE" -o jsonpath='{.spec.to.name}')
if [[ "$actual_service" != "$GW_SERVICE" ]]; then
  echo "ERROR: Route $ROUTE already exists but targets $actual_service, not $GW_SERVICE." >&2
  exit 1
fi

host=$(oc -n "$NS" get route "$ROUTE" -o jsonpath='{.spec.host}')
if [[ -z "$host" ]]; then
  echo "ERROR: Route has no hostname yet; check oc -n $NS describe route $ROUTE." >&2
  exit 1
fi

# The OpenShift router forwards the Route hostname as the HTTP Host header.
# Both Gateway API hostnames must match or Envoy will answer 404.
oc -n "$NS" patch gateway parks-gw --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/listeners/0/hostname\",\"value\":\"$host\"}]"
oc -n "$NS" patch httproute parks-api --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/hostnames/0\",\"value\":\"$host\"}]"

echo
echo "HTTPS Route: https://$host"
echo "Traffic: OpenShift Route -> $GW_SERVICE -> Gateway/HTTPRoute -> parks-api"
echo
echo "Check before testing auth/rate limits:"
echo "  oc -n $NS describe authpolicy parks-auth"
echo "  oc -n $NS describe ratelimitpolicy parks-rate-limits"
echo
echo "Test (after the policies show Enforced=True):"
echo "  curl -i -H 'Authorization: APIKEY alice-parks-demo-key' https://$host/ws/data/all"
