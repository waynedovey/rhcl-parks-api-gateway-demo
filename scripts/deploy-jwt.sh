#!/usr/bin/env bash
# Opt-in JWT demo extension. Does not alter the existing parks-api API-key policy.
set -euo pipefail

: "${KEYCLOAK_ISSUER_URL:?Set KEYCLOAK_ISSUER_URL=https://<trusted-keycloak-host>/realms/parks}"
ISSUER="${KEYCLOAK_ISSUER_URL%/}"
NS="rhcl-parks-demo"

case "$ISSUER" in
  https://*/realms/parks) ;;
  *) echo "Expected an HTTPS issuer ending /realms/parks, got: $ISSUER" >&2; exit 1 ;;
esac
for cmd in oc curl jq; do
  command -v "$cmd" >/dev/null || { echo "Missing executable: $cmd" >&2; exit 1; }
done

# Do not bypass certificate validation for the issuer. Authorino must trust it too.
DISCOVERED_ISSUER="$(curl --fail --silent --show-error "$ISSUER/.well-known/openid-configuration" | jq -er '.issuer')"
if [[ "$DISCOVERED_ISSUER" != "$ISSUER" ]]; then
  echo "OIDC issuer mismatch: discovered '$DISCOVERED_ISSUER', expected '$ISSUER'" >&2
  exit 1
fi

render_auth_policy() {
  # No secret material in this object; the client secret remains in Keycloak.
  cat <<YAML
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: parks-jwt-auth
  namespace: $NS
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: parks-jwt
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: "$ISSUER"
          audiences:
            - parks-api
YAML
}

echo "Checking all three objects against the live Kubernetes API schema..."
oc apply --dry-run=server -f docs/jwt/parks-jwt-httproute.yaml
render_auth_policy | oc apply --dry-run=server -f -
oc apply --dry-run=server -f docs/jwt/parks-jwt-rate-limits.yaml

echo "Applying optional JWT HTTPRoute, AuthPolicy and RateLimitPolicy..."
oc apply -f docs/jwt/parks-jwt-httproute.yaml
render_auth_policy | oc apply -f -
oc apply -f docs/jwt/parks-jwt-rate-limits.yaml

echo
echo "Check that HTTPRoute is Accepted/ResolvedRefs and both policies are Accepted/Enforced:"
oc -n "$NS" get httproute parks-jwt
oc -n "$NS" get authpolicy parks-jwt-auth
oc -n "$NS" get ratelimitpolicy parks-jwt-rate-limits
echo "Run: oc -n $NS describe httproute parks-jwt"
echo "Run: oc -n $NS describe authpolicy parks-jwt-auth"
echo "Run: oc -n $NS describe ratelimitpolicy parks-jwt-rate-limits"
echo "No changes were made to parks-auth, parks-rate-limits or parks-plans."
