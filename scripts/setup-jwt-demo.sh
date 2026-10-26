#!/usr/bin/env bash
# Extend the existing RHCL Parks API lab with RHBK, JWT validation and rate limits.
# Run from any cwd: bash scripts/setup-jwt-demo.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="rhcl-parks-demo"

for binary in oc openssl sed; do
  if ! command -v "$binary" >/dev/null 2>&1; then
    echo "ERROR: $binary is required." >&2
    exit 1
  fi
done

oc -n "$NS" get gateway parks-gw >/dev/null
oc -n "$NS" get httproute parks-api >/dev/null
oc -n "$NS" get deployment parks-api >/dev/null
oc -n "$NS" get route parks-api-gateway >/dev/null

# Gateway routing can work before RHCL policy enforcement is healthy.
if [[ -z "$(oc get kuadrant -A -o name 2>/dev/null)" ]]; then
  echo "ERROR: No Kuadrant instance exists; JWT authentication would not be enforced." >&2
  echo "Follow README prerequisite section to create a Ready Kuadrant instance." >&2
  exit 1
fi

parks_host="$(oc -n "$NS" get route parks-api-gateway -o jsonpath='{.spec.host}')"
gateway_host="$(oc -n "$NS" get gateway parks-gw -o jsonpath='{.spec.listeners[0].hostname}')"
if [[ -z "$parks_host" || "$parks_host" != "$gateway_host" ]]; then
  echo "ERROR: OpenShift Route and Gateway hostnames differ. Run bash scripts/expose-route.sh first." >&2
  exit 1
fi

if ! oc -n "$NS" get secret parks-keycloak-bootstrap >/dev/null 2>&1; then
  echo "Creating a random Keycloak bootstrap admin password in a Kubernetes Secret."
  bootstrap_password="$(openssl rand -hex 24)"
  oc -n "$NS" create secret generic parks-keycloak-bootstrap \
    --from-literal=username=admin \
    --from-literal=password="$bootstrap_password" \
    --dry-run=client -o yaml | oc apply -f -
  unset bootstrap_password
fi

oc -n "$NS" create configmap parks-keycloak-realm \
  --from-file=parks-realm.json="$ROOT_DIR/docs/keycloak-realm.json" \
  --dry-run=client -o yaml | oc apply -f -

if ! oc -n "$NS" get deployment parks-keycloak >/dev/null 2>&1; then
  oc apply -f "$ROOT_DIR/docs/keycloak-lab.yaml"
else
  echo "Using existing Keycloak Deployment (preserving its in-memory demo realm and client secret)."
  oc -n "$NS" get service parks-keycloak >/dev/null
fi

if ! oc -n "$NS" get route parks-keycloak >/dev/null 2>&1; then
  oc -n "$NS" create route edge parks-keycloak \
    --service=parks-keycloak \
    --port=http \
    --insecure-policy=Redirect
fi

route_service="$(oc -n "$NS" get route parks-keycloak -o jsonpath='{.spec.to.name}')"
if [[ "$route_service" != "parks-keycloak" ]]; then
  echo "ERROR: existing parks-keycloak Route points to $route_service, not parks-keycloak." >&2
  exit 1
fi

keycloak_host="$(oc -n "$NS" get route parks-keycloak -o jsonpath='{.spec.host}')"
if [[ -z "$keycloak_host" ]]; then
  echo "ERROR: Keycloak OpenShift Route hostname has not been assigned." >&2
  exit 1
fi
issuer="https://$keycloak_host/realms/parks"
oc -n "$NS" set env deployment/parks-keycloak KC_HOSTNAME="https://$keycloak_host"

echo "Waiting for the Keycloak rollout and imported parks realm..."
if ! oc -n "$NS" rollout status deployment/parks-keycloak --timeout=300s; then
  echo "Inspect: oc -n $NS describe pods -l app=parks-keycloak" >&2
  exit 1
fi

# Fail fast if a JWT policy field isn't recognised by the cluster's CRDs.
sed "s|__KC_ISSUER__|$issuer|g" "$ROOT_DIR/docs/jwt-protection-template.yaml" \
  | oc apply --dry-run=server -f -
sed "s|__KC_ISSUER__|$issuer|g" "$ROOT_DIR/docs/jwt-protection-template.yaml" \
  | oc apply -f -

echo
echo "Parks API: https://$parks_host"
echo "JWT API:   https://$parks_host/jwt/ws/data/all"
echo "Keycloak:  https://$keycloak_host"
echo "Issuer:    $issuer"
echo
echo "Get bootstrap admin password (macOS):"
echo "  oc -n $NS get secret parks-keycloak-bootstrap -o jsonpath='{.data.password}' | base64 -D"
echo
echo "NEXT: Open the Keycloak Route, log in as admin, select realm parks,"
echo "then Clients > parks-demo-client > Credentials to copy its client secret."
echo "Follow README.md section 6 for token requests and 200/401/429 tests."
echo "IMPORTANT: This development-mode Keycloak is for the lab only."
