# Module 6 — API Products and API Keys (RHCL 1.4 Technology Preview)

This module adds **API discovery, publication, access requests, manual approval, and API-key testing** to the Parks Gateway demo on OpenShift 4.22.18 and RHCL 1.4.3.

> **Technology Preview:** Red Hat documents API management in the OpenShift console as Technology Preview for RHCL 1.4. It is not covered by Red Hat production SLAs. Use this in a lab, not as a production API management design.

## What the feature does

```text
API owner -> APIProduct (National Parks API) -> API catalog
                                                  |
API consumer -> requests APIKey ------------------+
                                                  |
API owner -> manual approval ---------------------+
                                                  |
API consumer -> API key -> HTTPS Route -> RHCL AuthPolicy -> Parks API
```

- **APIProduct** wraps the existing Gateway API `HTTPRoute` (`parks-api`) with business metadata, documentation and an access-approval mode.
- **APIKey** represents a consumer's access request and associated credentials. Approval uses an `APIKeyRequest` shadow object and an `APIKeyApproval` decision.
- **AuthPolicy** still performs the actual data-plane authentication. Publishing a product does **not** itself secure the API or make an invalid policy valid.

## 1. Fix and validate existing policies first

From the repository root:

```bash
git pull --ff-only
bash scripts/check-policies.sh
```

If the output shows `Accepted=False` with `Reason=Invalid`, look at the **Message** field; it tells us why the policy was rejected. Share the output of the script (it deliberately does not print Secret values).

Also check:

```bash
oc get kuadrant -A
oc get authorino,limitador -A
```

The Parks manifest now sets `apiKey.allNamespaces: true`. This is needed because the three original demo keys are in `rhcl-parks-demo`, rather than Kuadrant's installation namespace. It also permits explicitly selected keys outside Kuadrant's namespace. For a shared or production environment use a carefully scoped design.

After an operator is Ready, you can reapply the manifest:

```bash
oc apply -f rhcl-parks-demo.yaml
bash scripts/expose-route.sh
bash scripts/check-policies.sh
```

The Route script must be rerun because reapplying the base manifest restores its placeholder Gateway hostname. **Do not move on until both policies report `Accepted=True` and `Enforced=True`.**

## 2. Confirm that API management is installed

```bash
oc api-resources --api-group=devportal.kuadrant.io
oc get apiproduct -A
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}'
```

Expected API management resources include `APIProduct`, `APIKey`, `APIKeyRequest`, and `APIKeyApproval`.

If those CRDs are missing, verify that the RHCL 1.4 deployment and its API-management components are installed. Don't apply the example `APIProduct` yet.

To enable the RHCL web-console plugin:

1. Open OpenShift Console → **Administration → Cluster Settings → Configuration**.
2. Select **Console** → **Console plugins**.
3. Enable **`kuadrant-console-plugin`**.
4. Wait for the console to reload.
5. Look for **Connectivity Link → API Products** and **Connectivity Link API Catalog → My API Keys / API Key Approvals**.

This is the OpenShift console plugin. You don't need Red Hat Developer Hub just to run this lab.

## 3. Publish the National Parks API product

We've added a reusable example `docs/api-product.yaml` that targets the existing `parks-api` **HTTPRoute**, plus an OpenAPI 3 contract at `docs/openapi.yaml`.

The OpenAPI document is served publicly from GitHub:

```text
https://raw.githubusercontent.com/waynedovey/rhcl-parks-api-gateway-demo/main/docs/openapi.yaml
```

After CRD checks and a healthy AuthPolicy, inspect the APIProduct schema:

```bash
oc explain apiproduct.spec --api-version=devportal.kuadrant.io/v1alpha1
oc apply --dry-run=server -f docs/api-product.yaml
```

Then publish:

```bash
oc apply -f docs/api-product.yaml
oc -n rhcl-parks-demo get apiproduct national-parks-api -o yaml
```

The product is configured as:

| Setting | Demo value |
| --- | --- |
| Name | National Parks API |
| Version | 1.0.0 |
| HTTPRoute | `rhcl-parks-demo/parks-api` |
| Visibility | `Published` |
| Approval | `manual` |
| API definition | `docs/openapi.yaml` |
| Docs | This GitHub repository |

You can also create/edit the product in **Connectivity Link → API Products** using the same fields. In the product details, confirm it discovered the attached AuthPolicy.

**If your installed Technology Preview CRD rejects any field**, trust `oc explain` and the specific server-side validation message for your actual Operator build. Do not force changes to CRDs.

## 4. Request an API key as a consumer

For a realistic two-team demo, you can use a separate, empty namespace:

```bash
oc create namespace rhcl-parks-consumer
```

If it already exists, simply reuse it.

In OpenShift Console:

1. Choose namespace **`rhcl-parks-consumer`**.
2. Open **Connectivity Link API Catalog → My API Keys**.
3. Click **Request API Key**.
4. Select **National Parks API**.
5. Enter a key name such as `parks-consumer-demo` and a short use case.
6. Select a service tier **only if one is offered** by a PlanPolicy (this demo does not install tiers).
7. Submit the request.

The key request should show **Pending**, because the product uses `approvalMode: manual`.

For a genuine role-separated demo, bind `api-catalog-browser` (cluster-wide discovery) and `api-consumer` in the consumer namespace to your test developer group. The API owner needs `api-owner` rights in the Parks namespace. A `cluster-admin` can walk through this demonstration without adding RBAC bindings, but that doesn't validate tenant separation.

## 5. Approve it as the API owner

Switch OpenShift Console to namespace **`rhcl-parks-demo`**.

1. Open **Connectivity Link API Catalog → API Key Approvals**.
2. Find the pending Parks request.
3. Review the use case and click **Approve**.
4. Return to **My API Keys** in the consumer namespace.
5. Open the approved key and use **Show API Key** to retrieve the credential.

Confirm the request/approval state without revealing key values:

```bash
oc -n rhcl-parks-demo get apikeyrequests,apikeyapprovals
oc -n rhcl-parks-consumer get apikeys
```

Do **not** print credential Secrets or paste API key values into GitHub, documentation or chat.

## 6. Call the live Parks API with the new key

Get the existing HTTPS Route:

```bash
export PARKS_URL="https://$(oc -n rhcl-parks-demo get route parks-api-gateway -o jsonpath='{.spec.host}')"
```

Enter the key interactively without placing the value into shell history:

```bash
read -r -s -p "Approved Parks API key: " PARKS_API_KEY
echo
curl -k -i -H "Authorization: APIKEY $PARKS_API_KEY" "$PARKS_URL/ws/data/all"
unset PARKS_API_KEY
```

**Expected:** `200` if the generated key is compatible with the existing API-key AuthPolicy and is correctly discovered. **If you get `401`:** check the policy's Secret selector, where the portal controller stores the enforcement Secret, its required labels, and the authentication header prefix. Do not assume a product approval guarantees a working gateway policy.

To demonstrate governance, revoke the key in the console and confirm it no longer authenticates.

## What is not included

- **PlanPolicy / subscription tiers:** The current Alice/Bob per-identity RateLimitPolicy is not a product subscription plan. Newly generated consumers aren't automatically assigned Bob's or Alice's rate limits. Plan-based subscriptions would be a separate module.
- **Production-ready identity:** This is a Technology Preview developer workflow. Production needs an agreed access model, robust RBAC, key rotation, auditing, TLS trust, and supported features.
- **Automated APIKey approval manifests:** The controller owns `APIKeyRequest` shadow resources, and consumer keys involve identity-specific Secrets. Use the console to demonstrate the correct lifecycle; don't manually create controller-managed shadow resources.
- **End-to-end cluster verification:** The manifest and docs are repository examples. The `Invalid` policy messages and controller readiness on your actual cluster still need examination.

## References

- [Red Hat RHCL 1.4 — API Products and API Keys](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/develop_apis_with_the_web_console/rhcl-api-management)
- [Red Hat RHCL 1.4 — Enable OpenShift console plugin](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/develop_apis_with_the_web_console/rhcl-ocp-web-console)
- [Kuadrant Developer Portal Controller — APIProduct example and CRD fields](https://github.com/Kuadrant/developer-portal-controller)
