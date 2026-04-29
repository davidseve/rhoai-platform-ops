# Authorino TLS Setup

## Overview

The `kuadrant-readiness-hook.yaml` PostSync hook configures Authorino with listener TLS and outbound `service-ca` trust, following the [official MaaS `setup-authorino-tls.sh`](https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/setup-authorino-tls.sh). This is required so Authorino can:

1. Accept TLS connections from the Gateway (Envoy → Authorino gRPC)
2. Make outbound HTTPS calls to `maas-api` for tier metadata lookup (Authorino → maas-api)

Without this setup, requests through the `maas-default-gateway` fail with **HTTP 500**.

## Background: Gateway 500 Errors (RHOAI ≤ 3.1)

> [!NOTE]
> This issue should **not** occur from RHOAI 3.2 onwards due to optional EnvoyFilter creation ([RHOAIENG-39326](https://issues.redhat.com/browse/RHOAIENG-39326)).
> With RHOAI 3.3.2 the fix should be fully stable — **pending validation on our clusters**.

### Symptom

All requests through the `maas-default-gateway` returned HTTP 500:

```
POST /maas-api/v1/tokens → 500 Internal Server Error
```

While:
- Direct ClusterIP calls to `maas-api` succeeded
- Tokens were valid (passed `TokenReview`)
- `HTTPRoutes` were `Accepted`
- No `maas-api` or Authorino logs were produced
- Removing `AuthPolicy` / `RateLimitPolicy` had no effect
- Even an `allow-anonymous` AuthPolicy still returned 500

This pattern indicates a data-plane `extAuthz` connectivity failure, not an authentication or routing error.

### Root Cause

OpenShift AI / KServe creates an EnvoyFilter (`openshift-ai-inference-authn-ssl`) that forces TLS origination for all Envoy traffic to the Authorino `extAuthz` upstream cluster. The failure chain:

1. The EnvoyFilter forces TLS on the Envoy → Authorino connection
2. Authorino was deployed in plain HTTP mode (no TLS listener)
3. Envoy initiated a TLS handshake; Authorino responded with plain HTTP
4. Connection failed at the transport socket layer — before any HTTP exchange
5. Envoy returned 500 immediately; no request ever reached Authorino or `maas-api`

The EnvoyFilter was intended only for the `openshift-ai-inference` gateway, but an [Istio bug in v1.26.2 / OSSM 3.1](https://github.com/istio/istio/issues/56417) caused it to apply to **all** gateways (including `maas-default-gateway`), because it has `priority: -1` and `targetRefs` scoping was not enforced correctly.

### Resolution

Align Authorino with the [official RHOAI GA KServe guide](https://github.com/opendatahub-io/kserve/tree/release-v0.15/docs/samples/llmisvc/ocp-setup-for-GA) for TLS-secured Authorino:

1. **Mint a serving certificate** — Annotate the service so OpenShift's `service-ca` operator generates a TLS cert:

```bash
oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system
```

2. **Enable listener TLS** — Patch the Authorino CR to use the generated cert:

```bash
oc patch authorino authorino -n kuadrant-system --type=merge -p '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {
          "name": "authorino-server-cert"
        }
      }
    }
  }
}'
```

3. **Mount service-ca for outbound trust** — So Authorino can call `maas-api` over HTTPS:

```bash
oc patch authorino authorino -n kuadrant-system --type=merge -p '{
  "spec": {
    "volumes": {
      "items": [{
        "name": "service-ca",
        "configMaps": ["openshift-service-ca.crt"],
        "mountPath": "/etc/ssl/certs/openshift-service-ca"
      }]
    }
  }
}'

oc set env deployment/authorino -n kuadrant-system \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca.crt
```

All three steps are automated by the `kuadrant-readiness-hook.yaml` PostSync hook. See [KUADRANT-READINESS-HOOK.md](KUADRANT-READINESS-HOOK.md) for details.

## RHOAI Version Matrix

| RHOAI Version | EnvoyFilter behavior | Authorino TLS required? | Status |
| ------------- | -------------------- | ----------------------- | ------ |
| 3.1           | Always created, leaks to all gateways (Istio bug) | **Yes** — without it, all extAuthz calls fail | Workaround applied |
| 3.2           | Optional creation ([RHOAIENG-39326](https://issues.redhat.com/browse/RHOAIENG-39326)) | Yes — still best practice, prevents future regressions | Supported |
| 3.3.2         | Fixed scoping expected | Yes — but the 500 bug should not occur even without it | **Pending validation** |

> [!IMPORTANT]
> RHOAI 3.3.2 should fully resolve the EnvoyFilter scoping issue. We need to validate on our clusters that:
> 1. The `openshift-ai-inference-authn-ssl` EnvoyFilter no longer leaks to `maas-default-gateway`
> 2. Authorino TLS setup still works correctly (listener TLS + outbound service-ca trust)
> 3. The PostSync hook completes without errors
>
> Track validation in the team's deployment checklist.

## How the Hook Automates This

The `kuadrant-readiness-hook.yaml` PostSync Job runs on every ArgoCD sync and performs:

1. Waits for Kuadrant CR readiness (handles `MissingDependency`)
2. Annotates the Authorino service for serving cert generation
3. Patches the Authorino CR for listener TLS + `service-ca` volume mount
4. Sets `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` env vars on the Authorino deployment
5. Restarts Limitador pods and waits for rollouts
6. Restarts Envoy Gateway pods to reload WasmPlugin config

See [KUADRANT-READINESS-HOOK.md](KUADRANT-READINESS-HOOK.md) for the full hook documentation.

## Involved Components

- **OpenShift Service Mesh (OSSM)** v3.x (Istio)
- **Kuadrant / Authorino** — `extAuthz` for Gateway API `AuthPolicies`
- **OpenShift AI / KServe** — creates the `openshift-ai-inference-authn-ssl` EnvoyFilter
- **Gateway API** — `maas-default-gateway` (MaaS) + `openshift-ai-inference` (KServe default)
- **Envoy** — ingress gateway that connects to Authorino over gRPC

## References

- [Root cause analysis (Bartosz Majsak)](https://gist.github.com/bartoszmajsak/99934c4acf39cd6639ae19efa985c0c6)
- [RHOAI GA KServe setup — SSL Authorino](https://github.com/opendatahub-io/kserve/tree/release-v0.15/docs/samples/llmisvc/ocp-setup-for-GA)
- [RHOAIENG-39326 — Optional EnvoyFilter creation](https://issues.redhat.com/browse/RHOAIENG-39326)
- [CONNLINK-528](https://issues.redhat.com/browse/CONNLINK-528)
- [Kuadrant/kuadrant-operator#1531](https://github.com/Kuadrant/kuadrant-operator/issues/1531)
- [istio/istio#56417 — EnvoyFilter scoping bug](https://github.com/istio/istio/issues/56417)
- [opendatahub-io/models-as-a-service#227 — Align MaaS with RHOAI/ODH](https://github.com/opendatahub-io/models-as-a-service/pull/227)
