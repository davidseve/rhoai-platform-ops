# MaaS Governance Stack — Architecture Notes

Applies to: RHOAI 3.4 GA on OCP 4.20+.

## GatewayClass

This deployment uses `gatewayClassName: data-science-gateway-class`, created automatically by RHOAI when KServe is `Managed` in the DataScienceCluster. Both `data-science-gateway-class` and `openshift-default` use the same controller (`openshift.io/gateway-controller/v1`) and produce identical Gateway behavior. We use `data-science-gateway-class` because it integrates with RHOAI's Authorino TLS bootstrap and MaaS controller.

## Gateway Configuration

```yaml
gatewayClassName: data-science-gateway-class
listeners:
- name: https
  port: 443
  protocol: HTTPS
  hostname: maas.apps.<cluster_domain>  # required for RHOAI dashboard API keys UI
  tls:
    mode: Terminate
    certificateRefs:
    - name: <wildcard-cert-secret>      # router-certs-default (bare-metal) or ingress-certs (cloud)
  allowedRoutes:
    namespaces:
      from: Selector                    # explicit namespace list (more restrictive than upstream's "All")
```

**Hostname**: The `hostname` field is required because the RHOAI dashboard (maas-ui) auto-discovers the MaaS endpoint as `maas.apps.<cluster_domain>`. Without a matching hostname on the Gateway listener, the dashboard shows "Error loading components". The hostname also enables SNI filtering — see [IN-CLUSTER-ACCESS.md](IN-CLUSTER-ACCESS.md) for the `--resolve` workaround.

**Route**: An OpenShift Route (`passthrough` TLS termination) fronts the Gateway for external access. The Route host must match the Gateway listener hostname.

## Authorino TLS Bootstrap

The annotation `security.opendatahub.io/authorino-tls-bootstrap: "true"` on the Gateway triggers the RHOAI platform to automatically configure an EnvoyFilter that enables TLS communication between the Gateway (Envoy) and Authorino.

This handles **inbound** TLS (Gateway → Authorino). For **outbound** TLS (Authorino → maas-api), the Authorino deployment must trust the OpenShift service-ca certificate. This is automated via the `authorino-tls` ArgoCD PostSync Job in `maas-platform` (equivalent to the upstream `scripts/setup-authorino-tls.sh`):

1. Annotate the maas-api Service for service-ca cert generation
2. Mount `openshift-service-ca.crt` ConfigMap into the Authorino deployment
3. Set `SSL_CERT_FILE` env var to the mounted CA path

Without this, API key validation fails with 403 (Authorino cannot reach maas-api's `/internal/v1/api-keys/validate` endpoint).

## Authentication: MaaSAuthPolicy

RHOAI 3.4 GA uses `MaaSAuthPolicy` instead of the RHOAI 3.3 `odh-model-controller` AuthPolicy. The maas-controller creates:

| Resource | Namespace | Purpose |
| --- | --- | --- |
| `gateway-default-auth` AuthPolicy | `openshift-ingress` | Gateway-level default deny (Enforced: False, overridden by per-model policies) |
| `maas-auth-<model>` AuthPolicy | `openshift-ingress` | Per-model auth with API key validation (Enforced: True) |
| `gateway-default-deny` TRLP | `openshift-ingress` | Default deny TokenRateLimitPolicy |
| `maas-trlp-<model>` TRLP | `openshift-ingress` | Per-model token rate limits from MaaSSubscription |

**Auth flow:**
1. Client sends request with `Authorization: Bearer sk-oai-...` (API key)
2. MaaSAuthPolicy calls maas-api `/internal/v1/api-keys/validate` to verify the key
3. maas-api returns the subscription, tier, and rate limit info
4. Kuadrant enforces token rate limits from the matching MaaSSubscription
5. Request is forwarded to the model pod

**OCP tokens** are only accepted for `/v1/models` (model listing). All inference requests require API keys.

The `opendatahub.io/managed: "false"` annotation on the Gateway prevents the maas-controller from managing our custom resources (e.g., the Gateway itself). Controller-created AuthPolicies and TRLPs coexist with Helm-managed resources without conflicts.

## MaaSSubscription Model

Rate limiting in RHOAI 3.4 GA uses MaaSSubscription CRs instead of custom RateLimitPolicy/TokenRateLimitPolicy. See [ADR-0005](../../../docs/adr/0005-maas-subscription-model.md) for the full decision record.

Each tier has a MaaSSubscription that defines:
- `owner.groups`: Kubernetes groups (from TokenReview) that map users to this tier
- `tokenRateLimits`: per-window token limits enforced by the controller's TRLP

The maas-controller creates the corresponding TokenRateLimitPolicy automatically based on the subscription. We define the subscription in the `maas-model` chart; the controller handles enforcement.

**Important**: `owner.groups` must use **Kubernetes groups** (from TokenReview), NOT OpenShift Group CRs. TokenReview returns groups like `cluster-admins`, `system:authenticated:oauth` — not custom Group objects like `maas-test-users`.

## Tenant CR and Telemetry

The `Tenant` CR (`maas.opendatahub.io/v1alpha1`) is auto-created by the maas-controller as `default-tenant` in `models-as-a-service`.

Setting `spec.telemetry.enabled: true` causes the controller to create:
- A `TelemetryPolicy` on the Gateway (adds labels to Limitador metrics)
- An Istio `Telemetry` CR for service-level telemetry

The TelemetryPolicy uses Kuadrant WASM expressions (`responseBodyJSON("/model")`, `auth.identity.selected_subscription`) that are NOT valid Authorino CEL. Authorino logs `failed to parse CEL expression` errors — these are **non-fatal** (metric label evaluation only, not auth decisions). The metric labels (`model`, `subscription`, etc.) will be empty until Kuadrant separates WASM and Authorino CEL expression evaluation in a future release.

We manage the Tenant via Helm template with ArgoCD `ServerSideApply=true`, which merges our `spec.telemetry` with the controller's auto-created Tenant. For Helm-only installs, the Makefile uses `oc patch` instead.

## Limitador Configuration

Limitador is the rate limiting engine used by Kuadrant. Our `limitador-patch` template enables `exhaustiveTelemetry`, which adds `limit_name` labels to all Limitador metrics (not just `limited_calls`). This is NOT managed by the controller — it must be set via Helm.

## Rate Limiting Architecture

```
MaaSSubscription (tier definition)
        │
        ▼
maas-controller (creates TRLP per subscription)
        │
        ▼
TokenRateLimitPolicy (token-based, per-tier)
        │
        ▼
   Limitador (per-tier token counters)
        │
   Metrics (with exhaustive labels)
        │
   ServiceMonitor → Prometheus → PrometheusRule (alerts)
```

## Comparison with RHOAI 3.3

| Feature | RHOAI 3.3 | RHOAI 3.4 GA |
| --- | --- | --- |
| GatewayClass | `openshift-default` (our choice) | `data-science-gateway-class` (RHOAI managed) |
| Auth mechanism | Custom AuthPolicy (PostSync hook) | MaaSAuthPolicy (controller managed) |
| Rate limits | Custom RLP + TRLP | MaaSSubscription → controller TRLP |
| Auth tokens | MaaS tokens (via `/maas-api/v1/tokens`) | API keys (`sk-oai-*` via `/maas-api/v1/api-keys`) |
| `opendatahub.io/managed: "false"` | Ignored (required PostSync hook) | Works correctly |
| Telemetry | Manual TelemetryPolicy + Istio CR | Tenant CR → controller auto-creates |
| Model paths | `/<model>/v1/...` | `/<namespace>/<model>/v1/...` |
| PostSync hooks needed | `cleanup-authn-hook`, `kuadrant-readiness-hook` | `authorino-tls` only |

## Known Limitations (RHOAI 3.4 GA)

1. **TelemetryPolicy CEL expressions non-fatal** — Kuadrant WASM expressions in TelemetryPolicy are not valid Authorino CEL. Metric labels for `model` and `subscription` are empty. Per-model attribution in dashboards not possible until Kuadrant separates expression evaluation.

2. **No request-level rate limiting** — MaaSSubscription only creates TokenRateLimitPolicy. Request-level limits require a custom RateLimitPolicy.

3. **Gateway tracing not available** — The managed Istio (cluster-ingress-operator) cannot be customized with `extensionProviders` for OpenTelemetry. Gateway-level trace spans require OSSM 3 or upstream Kuadrant tracing support. WASM trace ID propagation (Limitador) also not available.

4. **vLLM CPU x86_64 not published by Red Hat** — Red Hat's `odh-vllm-cpu-rhel9` image only supports ppc64le/s390x. Custom image `quay.io/dseveria/vllm-cpu-openai-ubi9:0.3-otel` remains necessary for x86_64 CPU inference.

5. **Gateway→Authorino listener TLS** — Upstream `setup-authorino-tls.sh` enables `listener.tls.enabled: true` on Authorino, but the Kuadrant EnvoyFilter does not include `transport_socket`. Internal Gateway→Authorino traffic stays plaintext (intra-cluster). See ROADMAP.md for details.

See [ADR-0005](../../../docs/adr/0005-maas-subscription-model.md) for the full MaaS Subscription decision record.
