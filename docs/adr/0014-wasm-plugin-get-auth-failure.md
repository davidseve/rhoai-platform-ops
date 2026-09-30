# ADR-0014: Kuadrant Wasm Plugin GET Request Auth Failure

## Status
Resolved — Service Mesh 3.3.1 ships Envoy 1.36.6-dev which supports `allow_on_headers_stop_iteration`.

## Context

On RHOAI 3.4.x (both 3.4.0 and 3.4.1), the Kuadrant Wasm plugin cannot authenticate HTTP GET requests through the MaaS Gateway. POST requests (model inference) work correctly. This affects:

- `GET /v1/models` → 500 AUTH_FAILURE ("Missing or empty username header: X-MaaS-Username")
- `GET /maas-api/v1/api_keys` → 404 (auth bypassed, path doesn't resolve without user context)
- RHOAI Dashboard "API Keys" and "Models" pages when accessed via the MaaS Gateway

### Root Cause

The Kuadrant Wasm shim (injected via EnvoyFilter `kuadrant-maas-default-gateway`) uses the `allow_on_headers_stop_iteration` configuration field to pause request processing during the `on_request_headers` phase and dispatch the authentication call to Authorino.

**This field is not supported by Envoy 1.34.2-dev** (bundled with OpenShift Service Mesh 3.3.4). It was introduced in Envoy 1.35.0 as part of the proxy-wasm ABI enhancements.

Evidence from gateway pod logs (Envoy 1.34.x only):
```
warning envoy config: Unknown field: 'allow_on_headers_stop_iteration'
warning wasm kuadrant_wasm_shim: Missing json property: /model
error   wasm kuadrant_wasm_shim: Task failed: Some("0")
```

**For POST requests** (inference): the Wasm plugin processes the request body phase, where it can successfully extract the model name from the JSON payload and dispatch the auth call. This is why inference works.

**For GET requests** (no body): the plugin cannot pause at the headers phase (unsupported field) and there is no body phase to fall back to. The auth call is never dispatched, so the request reaches `maas-api` without the `X-MaaS-Username` header that Authorino would normally set.

### Tested Configurations

| RHOAI | Service Mesh | Envoy | Result |
|-------|-------------|-------|--------|
| 3.4.0 | 3.3.4 | 1.34.2-dev | GET: 500, POST: 200 |
| 3.4.1 | 3.3.4 | 1.34.2-dev | GET: 500, POST: 200 |
| 3.4.4 | 3.3.1 | 1.36.6-dev | GET: 200, POST: 200 |

## Options Considered

### Option 1: Wait for Service Mesh update with Envoy 1.35+ (recommended)
- **Pros:** Proper fix at the source; no workarounds needed
- **Cons:** Depends on Red Hat's Service Mesh release timeline; no ETA

### Option 2: Custom EnvoyFilter with ext_authz for GET paths
Create a separate EnvoyFilter that applies `envoy.filters.http.ext_authz` (native Envoy filter, not Wasm) to the `maas-default-gateway` for GET-only paths (`/v1/models`, `/maas-api/*`). Map the `x-auth-request-user` response header to `X-MaaS-Username` via a Lua filter.
- **Pros:** Works around the Wasm limitation; uses proven Envoy filters
- **Cons:** Complex; requires maintaining a parallel auth path; may conflict with Kuadrant policies

### Option 3: Separate GatewayClass for MaaS
Use a custom `GatewayClass` (as in [alvarolop/rhoai-gitops](https://github.com/alvarolop/rhoai-gitops)) instead of the shared `data-science-gateway-class`. This may affect Istio revision or Envoy configuration.
- **Pros:** Isolates the MaaS gateway from RHOAI-managed components
- **Cons:** Does not address the Envoy version issue; same Wasm plugin is applied

### Option 4: Report as bug to Kuadrant/RHCL team
- **Pros:** Gets upstream attention; may result in a Wasm shim fix that doesn't require `allow_on_headers_stop_iteration`
- **Cons:** No guaranteed timeline

## Decision

**Option 1 delivered.** Service Mesh 3.3.1 ships Envoy 1.36.6-dev which supports `allow_on_headers_stop_iteration`. Both GET and POST requests are now properly authenticated through the Wasm plugin.

### Prerequisites for full gateway auth

The Envoy/Wasm fix is necessary but not sufficient. The `authorino-tls-setup` PostSync Job must also complete successfully. It configures:

1. Authorino listener TLS (serving cert from OpenShift service-CA)
2. OpenShift service-CA ConfigMap mounted as volume in the Authorino deployment
3. `SSL_CERT_FILE` env var pointing to the CA bundle

Without this setup, Authorino cannot call the maas-api HTTPS endpoints for API key validation and subscription selection (TLS handshake fails: `tls: bad certificate`). The PostSync Job uses `ose-cli:latest` which must reference the cluster ImageStream (see `hookImage` in `maas-platform/values.yaml`).

## Consequences

### What Works (Envoy 1.36.6-dev + Authorino TLS configured)
- Model inference via POST requests (all models) — 200
- Model listing via GET `/v1/models` with K8s token — 200
- API key creation via POST `/maas-api/v1/api-keys` — 200
- MaaS Subscriptions, AuthPolicies, TokenRateLimitPolicies — all Active/Enforced
- Unauthenticated requests — 401 (correctly rejected)
- Cross-subscription requests — 403 (correctly rejected)
- Authorino TLS — properly configured
- RHOAI Dashboard — accessible (frontend SPA loads)
- Grafana dashboards — functional

### What Doesn't Work
- Envoy 1.34.x (Service Mesh 3.3.4): GET requests still fail with 500 AUTH_FAILURE

## References
- Envoy proxy-wasm ABI: `allow_on_headers_stop_iteration` [proxy-wasm spec](https://github.com/proxy-wasm/spec)
- Service Mesh 3.3.4 ships Envoy 1.34.2-dev (broken)
- Service Mesh 3.3.1 ships Envoy 1.36.6-dev (fixed)
- Related: [ADR-0011](0011-kuadrant-istio-race-condition.md) (Kuadrant/Istio race condition)
- Reference repo: [alvarolop/rhoai-gitops](https://github.com/alvarolop/rhoai-gitops)
