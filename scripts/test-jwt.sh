#!/usr/bin/env bash
# Safe, low-volume JWT verification smoke test (not a load/DDoS test).
set -euo pipefail

: "${KEYCLOAK_ISSUER_URL:?Set KEYCLOAK_ISSUER_URL=https://<trusted-keycloak-host>/realms/parks}"
ISSUER="${KEYCLOAK_ISSUER_URL%/}"
NS="rhcl-parks-demo"
for cmd in oc curl jq base64; do
  command -v "$cmd" >/dev/null || { echo "Missing executable: $cmd" >&2; exit 1; }
done

PARKS_URL="https://$(oc -n "$NS" get route parks-api-gateway -o jsonpath='{.spec.host}')"
CLIENT_SECRET="$(oc -n keycloak get secret parks-client-secret -o jsonpath='{.data.secret}' | base64 -d)"
TOKEN_JSON="$(curl --fail --silent --show-error -X POST \
  "$ISSUER/protocol/openid-connect/token" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode client_id=parks-demo-cli \
  --data-urlencode "client_secret=$CLIENT_SECRET")"
unset CLIENT_SECRET
JWT_TOKEN="$(printf '%s' "$TOKEN_JSON" | jq -er '.access_token')"
unset TOKEN_JSON

echo "API: $PARKS_URL/jwt/ws/data/all"
echo "No JWT (expected 401):"
curl -k -s -o /dev/null -w 'HTTP %{http_code}\n' "$PARKS_URL/jwt/ws/data/all"
echo "Invalid JWT (expected 401):"
curl -k -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -H 'Authorization: Bearer invalid-token' "$PARKS_URL/jwt/ws/data/all"
echo "Valid JWT (expected 200):"
curl -k -s -o /dev/null -w 'HTTP %{http_code}\n' \
  -H "Authorization: Bearer $JWT_TOKEN" "$PARKS_URL/jwt/ws/data/all"

echo "Small burst of 7 requests (expected some 429 responses, after policy enforcement):"
for _ in 1 2 3 4 5 6 7; do
  curl -k -s -o /dev/null -w '%{http_code} ' \
    -H "Authorization: Bearer $JWT_TOKEN" "$PARKS_URL/jwt/ws/data/all"
done
echo
unset JWT_TOKEN
echo "This verifies application-rate limiting only; it is NOT a DDoS-resilience test."
