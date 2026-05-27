# Gateway and Route Configuration

The MaaS Gateway is exposed externally via an OpenShift Route. There are two TLS termination strategies.

## How TLS works in each mode

```
PASSTHROUGH:
  Client ──TLS──► OpenShift Router ──TLS (same)──► Gateway (Istio/Envoy)
  The router does NOT terminate TLS. It forwards encrypted traffic
  directly to the Gateway based on SNI.
  The Gateway's TLS certificate must match the external hostname.

REENCRYPT:
  Client ──TLS──► OpenShift Router ──new TLS──► Gateway (Istio/Envoy)
  The router terminates the client's TLS using its own wildcard cert,
  then opens a NEW TLS connection to the Gateway using a separate cert.
  The Gateway's cert does NOT need to match the external hostname.
```

## Option A: Passthrough (default)

TLS goes from the client directly to the Gateway. The OpenShift Router acts as a TCP proxy.

**Requirements:**

- The Gateway must use a TLS certificate matching `maas.<clusterDomain>`.
- This is typically the cluster's wildcard certificate (`*.apps.<clusterDomain>`).

```yaml
gateway:
  tlsSecretName: ingress-certs          # AWS
  # tlsSecretName: router-certs-default # bare-metal

route:
  tlsTermination: passthrough
```

**Wildcard certificate secret by platform:**

| Platform | Secret name | Notes |
| --- | --- | --- |
| AWS (ROSA, IPI) | `ingress-certs` | Let's Encrypt or ACM cert |
| Bare-metal / UPI | `router-certs-default` | Self-signed or custom CA |
| Custom | `oc get secret -n openshift-ingress \| grep tls` | Check your cluster |

## Option B: Reencrypt

The OpenShift Router terminates external TLS and establishes a new TLS connection to the Gateway using a service-ca certificate.

```yaml
gateway:
  tlsSecretName: maas-gateway-service-tls

route:
  tlsTermination: reencrypt
```

**Additional step** (after Gateway Service is created):

```bash
oc annotate svc maas-default-gateway-data-science-gateway-class \
  -n openshift-ingress \
  service.beta.openshift.io/serving-cert-secret-name=maas-gateway-service-tls
```

## Decision guide

| Scenario | Mode | Gateway cert | Why |
| --- | --- | --- | --- |
| AWS with known wildcard cert | **passthrough** | `ingress-certs` | Simple, no extra steps |
| Bare-metal with `router-certs-default` | **passthrough** | `router-certs-default` | Simple |
| Unknown platform / multi-cluster | **reencrypt** | `maas-gateway-service-tls` | Platform-independent |

## Production Hardening

### The 200ms constraint

Kuadrant's WASM filter has a **hardcoded 200ms timeout** with `failureMode: deny`. If Authorino takes longer than 200ms to evaluate authentication, the WASM filter returns HTTP 500 and the request never reaches vLLM. This timeout is not configurable.

```
Client → Route → Gateway (Envoy) → WASM filter ─┬─ Authorino (auth)     ← 200ms budget
                                                  └─ Limitador (rate limit)
                                   Gateway → vLLM (inference)
```

### Authorino sizing

| Setting | Value | Rationale |
| --- | --- | --- |
| Replicas | 2 | HA during node drains; distribute auth load |
| CPU request | 250m | Baseline for auth evaluation + TLS handshakes |
| CPU limit | 1 | Headroom for cold-start auth (no cache hit) |
| Memory request | 512Mi | Authorino caches auth responses in memory |
| Memory limit | 1Gi | Safety margin for cache growth under load |

The PostSync Job (`authorino-tls-job.yaml`) patches both the Authorino CR (replicas) and the Deployment (resource limits). The operator manages replicas from the CR but does not reconcile resource limits on the Deployment, so the patch is stable.

### Limitador sizing

| Setting | Value | Rationale |
| --- | --- | --- |
| Replicas | 2 | HA; rate limit state is local per replica |
| CPU request | 100m | Rate limit evaluation is lightweight |
| CPU limit | 500m | Burst capacity for high-concurrency spikes |
| Memory request | 128Mi | Counter storage is small |
| Memory limit | 256Mi | Limitador is memory-efficient |

Replicas and resources are set directly on the Limitador CR (`limitador-patch.yaml`), which the operator reconciles into the Deployment.

### PodDisruptionBudgets

Both Authorino and Limitador have PDBs with `minAvailable: 1`. This guarantees at least one pod survives voluntary disruptions (node drains, rolling updates). Without PDBs, a rolling update could briefly leave zero auth/rate-limit pods, causing 500 errors from the WASM filter.

### Monitoring

Two alerts detect auth pipeline degradation before it impacts users:

- **MaaSAuthTimeoutRateHigh**: auth errors exceed 1% of total requests for 5 minutes. Indicates Authorino is timing out under the 200ms WASM deadline.
- **MaaSAuthorinoCPUSaturation**: Authorino pod CPU usage exceeds 80% of its limit for 5 minutes. Early warning that auth evaluations will start exceeding 200ms.

### Client retry guidance

Clients should implement exponential backoff for 5xx errors from the gateway:

- **500 from WASM filter**: auth pipeline timed out. Retry after 1-2 seconds.
- **503 Service Unavailable**: Authorino/Limitador pod restarting. Retry after 2-5 seconds.
- **429 Too Many Requests**: rate limit exceeded. Respect the `Retry-After` header.

Recommended: max 3 retries with jitter, initial delay 1 second, backoff factor 2.
