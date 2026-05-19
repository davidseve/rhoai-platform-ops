# Authorino TLS Setup

## Overview

The `authorino-tls-job.yaml` ArgoCD PostSync Job configures Authorino with two TLS capabilities required for MaaS to function:

1. **Listener TLS** (Gateway → Authorino) — Envoy connects to Authorino over gRPC for `extAuthz`. The Gateway controller creates an EnvoyFilter (`*-authn-ssl`) that forces TLS on this connection. Authorino must have a valid serving certificate.
2. **Outbound CA trust** (Authorino → maas-api) — Authorino calls `maas-api` over HTTPS to validate API keys. Since `maas-api` uses an OpenShift `service-ca`-signed certificate, Authorino must trust the cluster CA.

Without this setup, Gateway requests fail with **HTTP 500** (listener TLS) or **HTTP 403** (outbound CA trust).

## How it works (8 steps)

The PostSync Job in `modules/maas/charts/maas-platform/templates/gateway/authorino-tls-job.yaml` runs after every ArgoCD sync:

| Step | Action | Why |
| ---- | ------ | --- |
| 1 | Annotate Authorino service with `serving-cert-secret-name` | Triggers OpenShift service-ca to generate a TLS cert |
| 2 | Wait for cert secret | The annotation is async; cert appears after ~5s |
| 3 | Patch Authorino CR `listener.tls.enabled: true` | Authorino starts accepting TLS on its gRPC listener |
| 4 | Create `openshift-service-ca.crt` ConfigMap | Injected with cluster CA bundle by service-ca operator |
| 5 | Mount ConfigMap as volume on Authorino deployment | Makes the CA cert file available to the container |
| 6 | Set `SSL_CERT_FILE` env var | Go's `crypto/tls` uses this for outbound verification |
| 7 | Wait for Authorino readiness | Steps 5-6 trigger a rollout; wait for all replicas ready |
| 8 | Trigger Gateway EnvoyFilter reconciliation | Annotate Gateway to create `*-authn-ssl` EnvoyFilter |

Steps 1-3 solve listener TLS. Steps 4-6 solve outbound CA trust. Step 8 ensures the Gateway data plane is updated.

## RBAC

The Job creates two Roles (not ClusterRoles) with minimal permissions:

**`authorino-tls-setup`** in `kuadrant-system`:
- `services`: get, update, patch (annotate service)
- `secrets`: get (read cert secret)
- `configmaps`: get, create, update, patch (service-ca ConfigMap)
- `deployments`: get, update, patch (volume mount, env var)
- `authorinos`: get, patch (enable listener TLS)

**`authorino-tls-gateway`** in `openshift-ingress`:
- `gateways`: get, update, patch (annotate for EnvoyFilter)
- `envoyfilters`: get, list (check if already created)

All hook resources use `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation`.

> **Note on `patch` verb**: `oc annotate`, `oc set volume`, and `oc set env` use the HTTP PATCH method internally. RBAC rules must include `patch`, not just `update`.

## Manual deployment (without ArgoCD)

When deploying with `helm install` (no PostSync hooks), run the equivalent steps:

```bash
NS=kuadrant-system
GATEWAY_NS=openshift-ingress
GATEWAY_NAME=maas-default-gateway

# Step 1: Annotate Authorino service for serving cert
oc annotate service authorino-authorino-authorization -n $NS \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite

# Step 2: Wait for cert secret
oc wait --for=jsonpath='{.type}'=kubernetes.io/tls secret/authorino-server-cert \
  -n $NS --timeout=60s 2>/dev/null || \
  echo "Waiting for cert..." && sleep 10

# Step 3: Enable listener TLS on Authorino
oc patch authorino authorino -n $NS --type=merge -p '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {"name": "authorino-server-cert"}
      }
    }
  }
}'

# Step 4: Create service-ca ConfigMap
oc create configmap openshift-service-ca.crt -n $NS 2>/dev/null || true
oc annotate configmap openshift-service-ca.crt -n $NS \
  service.beta.openshift.io/inject-cabundle=true --overwrite

# Step 5: Mount volume
oc set volume deploy/authorino -n $NS --add \
  --name=openshift-service-ca \
  --type=configmap \
  --configmap-name=openshift-service-ca.crt \
  --mount-path=/etc/ssl/certs/openshift-service-ca \
  --read-only

# Step 6: Set SSL_CERT_FILE
oc set env deploy/authorino -n $NS \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca.crt

# Step 7: Wait for readiness
oc rollout status deploy/authorino -n $NS --timeout=120s

# Step 8: Trigger EnvoyFilter
oc annotate gateway $GATEWAY_NAME -n $GATEWAY_NS \
  security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
```

## Diagnosing issues

```bash
# Check listener TLS config
oc get authorino authorino -n kuadrant-system \
  -o jsonpath='{.spec.listener.tls}'

# Check SSL_CERT_FILE env var
oc get deploy authorino -n kuadrant-system \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SSL_CERT_FILE")].value}'

# Check service-ca volume mount
oc get deploy authorino -n kuadrant-system \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="openshift-service-ca")]}'

# Check EnvoyFilter exists
oc get envoyfilter -n openshift-ingress | grep authn-ssl

# Check for TLS errors (should be empty after fix)
oc logs deploy/authorino -n kuadrant-system --tail=50 | grep -E "tls|certificate|x509"

# Check PostSync Job logs
oc logs job/authorino-tls-setup -n kuadrant-system
```

## Background

### Why Authorino needs listener TLS

OpenShift AI / KServe configures the Gateway's Envoy proxy to connect to Authorino over TLS for `extAuthz` checks. When the Gateway annotation `security.opendatahub.io/authorino-tls-bootstrap: "true"` is set, the Kuadrant controller creates an EnvoyFilter (`*-authn-ssl`) that forces TLS transport on the Envoy → Authorino connection. If Authorino has no TLS listener, this connection fails at the transport layer — Envoy returns HTTP 500 before any request reaches Authorino.

### Why Authorino needs service-ca trust

MaaS API keys (`sk-oai-*`) are validated by Authorino calling `maas-api`'s `/internal/v1/api-keys/validate` endpoint over HTTPS. The `maas-api` service uses an OpenShift `service-ca`-signed certificate. Authorino's base image includes ~148 public CA certificates but **not** the OpenShift `service-ca` CA. Without mounting the CA bundle and setting `SSL_CERT_FILE`, Authorino returns HTTP 403 (auth failure) because it cannot verify the maas-api certificate.

## References

- [Official MaaS setup-authorino-tls.sh](https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/setup-authorino-tls.sh)
- [RHOAI GA KServe setup — SSL Authorino](https://github.com/opendatahub-io/kserve/tree/release-v0.15/docs/samples/llmisvc/ocp-setup-for-GA)
- [RHOAI 3.4 MaaS documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4)

## Version History

| RHOAI | Hook file | Notes |
| ----- | --------- | ----- |
| 3.1–3.3 | `kuadrant-readiness-hook.yaml` | Also handled Kuadrant MissingDependency recovery + Limitador/Envoy restarts |
| 3.4 GA | `authorino-tls-job.yaml` | Simplified to TLS-only (MissingDependency no longer occurs in 3.4) |
