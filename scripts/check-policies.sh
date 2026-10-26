#!/usr/bin/env bash
# Read-only RHCL policy diagnostics; no Secret values are displayed.
set -euo pipefail

NS="rhcl-parks-demo"

echo "=== RHCL components ==="
oc get kuadrant -A || true
oc get authorino,limitador -A || true

echo
echo "=== Gateway and HTTPRoute conditions ==="
oc -n "$NS" get gateway parks-gw -o yaml | sed -n '/^status:/,$p' || true
oc -n "$NS" get httproute parks-api -o yaml | sed -n '/^status:/,$p' || true

echo
echo "=== AuthPolicy: Accepted and Enforced ==="
oc -n "$NS" get authpolicy parks-auth \
  -o jsonpath='{range .status.conditions[*]}{.type}{" = "}{.status}{" | "}{.reason}{" | "}{.message}{"\n"}{end}' || true
echo

echo
echo "=== RateLimitPolicy: Accepted and Enforced ==="
oc -n "$NS" get ratelimitpolicy parks-rate-limits \
  -o jsonpath='{range .status.conditions[*]}{.type}{" = "}{.status}{" | "}{.reason}{" | "}{.message}{"\n"}{end}' || true
echo

echo
echo "=== Descriptions (events and detailed reasons) ==="
oc -n "$NS" describe authpolicy parks-auth || true
oc -n "$NS" describe ratelimitpolicy parks-rate-limits || true

echo
echo "=== API management CRDs, if installed ==="
oc api-resources --api-group=devportal.kuadrant.io || true

echo
echo "Review any Accepted=False/Invalid reason before modifying the policy."
