# MaaS Observability

Observability stack for MaaS (Models-as-a-Service) on RHOAI 3.4, aligned with [Red Hat Connectivity Link (RHCL) 1.3 observability](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/observability/rhcl-observability) and upstream [Kuadrant observability](https://docs.kuadrant.io/latest/kuadrant-operator/doc/observability/).

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Grafana (observability ns)                │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐ │
│  │ Platform     │ │ Tier Usage   │ │ Gateway Infra        │ │
│  │ Overview     │ │              │ │ (gateway-api-state-  │ │
│  │              │ │              │ │  metrics)            │ │
│  └──────┬───────┘ └──────┬───────┘ └──────────┬───────────┘ │
│         │                │                    │             │
│  ┌──────┴────────────────┴────────────────────┴───────────┐ │
│  │              Thanos Querier (Prometheus)                │ │
│  └────────────────────────┬───────────────────────────────┘ │
│         ┌──────────┐      │                                 │
│         │ Tempo    │      │                                 │
│         │ (traces) │      │                                 │
│         └────┬─────┘      │                                 │
└──────────────┼────────────┼─────────────────────────────────┘
               │            │
    ┌──────────┴───┐   ┌────┴──────────────────────────────┐
    │ OTel         │   │ User Workload Monitoring          │
    │ Collector    │   │   ┌───────────────────────────┐   │
    │ (spanmetrics)│   │   │ ServiceMonitor: Limitador │   │
    └──────────────┘   │   │ PodMonitor: vLLM          │   │
                       │   │ ServiceMonitor: gateway-   │   │
                       │   │   api-state-metrics        │   │
                       │   └───────────────────────────┘   │
                       └───────────────────────────────────┘
```

## Metrics Sources

### 1. Limitador (rate limiter)

**ServiceMonitor:** `limitador-metrics` in `kuadrant-system`

Key metrics:
| Metric | Type | Description |
|--------|------|-------------|
| `authorized_calls` | Counter | Requests that passed rate limit checks |
| `limited_calls` | Counter | Requests rejected by rate limits |
| `authorized_hits` | Counter | Token usage per user/tier (with `limit_name` label) |
| `limitador_up` | Gauge | Health check (1 = up) |
| `datastore_partitioned` | Gauge | Datastore connectivity (1 = partitioned) |

The `limit_name` Prometheus label is enabled via `exhaustiveTelemetry: true` in `maas-platform/values.yaml`. This enriches `authorized_calls` and `limited_calls` (not just `limited_calls`) with the limit name, allowing per-tier breakdowns.

> **Upstream reference:** Limitador enables this via `LIMIT_NAME_IN_PROMETHEUS_LABELS` flag. Disabled by default due to cardinality risk; we enable it because our tier count is small and bounded.

### 2. Istio/Envoy (gateway data plane)

Envoy metrics are exposed automatically when Istio is present:

| Metric | Type | Description |
|--------|------|-------------|
| `istio_requests_total` | Counter | Requests with `response_code`, `source_workload`, `destination_workload` labels |
| `istio_request_duration_milliseconds` | Histogram | Request latency |

The `TelemetryPolicy` (Kuadrant extension) is configured to enrich these with custom labels (`model`, `user`, `subscription`), but the CEL expressions are Kuadrant WASM functions (`responseBodyJSON()`, `auth.identity.selected_subscription`) that Authorino cannot parse. These errors are non-fatal in RHOAI 3.4 GA — auth works, but Istio metric labels are empty.

> **Workaround:** Per-subscription and per-model metrics use Limitador native metrics (`authorized_calls`, `authorized_hits`, `limited_calls`) which have `subscription`, `model`, and `limit_name` labels. Per-user metrics are not available — maas-api does not expose a `/metrics` endpoint (upstream gap).
>
> **RHOAI 3.5+:** Re-evaluate when Kuadrant separates WASM and Authorino CEL expression evaluation.

### 3. Gateway API State Metrics (kube-state-metrics)

**Deployment:** `gateway-api-state-metrics` in `observability` namespace

A dedicated kube-state-metrics instance running in `--custom-resource-state-only` mode. Exposes Prometheus Gauge/Info metrics for Gateway API and Kuadrant custom resources without requiring code changes in any controller.

**Monitored resources:**

| Resource | Metric Prefix | Metrics |
|----------|---------------|---------|
| Gateway | `gatewayapi_gateway_` | info, status, listener_info, attached_routes, address_info |
| GatewayClass | `gatewayapi_gatewayclass_` | info, status, supported_features |
| HTTPRoute | `gatewayapi_httproute_` | labels, hostname_info, parent_info, status_parent_info |
| GRPCRoute | `gatewayapi_grpcroute_` | labels, parent_info, status_parent_info |
| AuthPolicy | `gatewayapi_authpolicy_` | target_info, status |
| RateLimitPolicy | `gatewayapi_ratelimitpolicy_` | target_info, status |
| TLSPolicy | `gatewayapi_tlspolicy_` | target_info, status |
| DNSPolicy | `gatewayapi_dnspolicy_` | target_info, status |

**How it works:** The ConfigMap `gateway-api-state-metrics` contains a `CustomResourceStateMetrics` spec that maps CRD `.status.conditions`, `.spec.targetRef`, `.spec.listeners`, etc. to Prometheus metrics. kube-state-metrics watches these CRDs via the Kubernetes API (ClusterRole grants `list`+`watch` on all target resources).

> **Source:** [gateway-api-state-metrics](https://github.com/Kuadrant/gateway-api-state-metrics) — the Kuadrant project's reference implementation. Our config covers the same resources as upstream but omits TLSRoute/TCPRoute/UDPRoute and BackendTLSPolicy (unused in our setup).

### 4. Kuadrant Operator Metrics

Kuadrant 1.3 operator exposes metrics when `observability.enable: true` is set in the Kuadrant CR:

| Metric | Type | Description |
|--------|------|-------------|
| `kuadrant_policies_total` | Gauge | Total policies by `kind` |
| `kuadrant_policies_enforced` | Gauge | Enforcement status by `kind` and `status` |
| `kuadrant_ready` | Gauge | Kuadrant CR readiness |
| `kuadrant_component_ready` | Gauge | Authorino/Limitador readiness by `component` |

> **Gap:** We don't currently configure `observability.enable: true` in the Kuadrant CR. This is managed by the RHOAI operator's DSC component, not directly by us. If these metrics become available, add a ServiceMonitor.

### 5. Authorino (auth server)

Authorino exposes two metric endpoints on port 8080:
- `/metrics`: controller-runtime reconciliation metrics
- `/server-metrics`: auth server gRPC/OIDC metrics

Key server metrics:
| Metric | Type | Description |
|--------|------|-------------|
| `auth_server_response_status` | Counter | Auth responses by `status` (OK, UNAUTHENTICATED, PERMISSION_DENIED) |
| `auth_server_authconfig_duration_seconds` | Histogram | Auth evaluation latency per AuthConfig |
| `auth_server_evaluator_*` | Counter/Histogram | Per-evaluator metrics (opt-in via `metrics: true` in AuthConfig) |

> **Gap:** We don't scrape Authorino metrics directly. RHCL 1.3 documents ServiceMonitors for `authorino-operator-metrics`. These are likely created by the Kuadrant operator; verify with `oc get servicemonitor -n kuadrant-system`.

### 6. vLLM (model serving)

**PodMonitor:** `vllm-metrics` in model namespace

Scrapes KServe/vLLM predictor pods via HTTPS (requires `service-ca-bundle` ConfigMap for TLS).

Key metrics:
| Metric | Type | Description |
|--------|------|-------------|
| `kserve_vllm:e2e_request_latency_seconds_bucket` | Histogram | End-to-end inference latency |
| `kserve_vllm:gpu_cache_usage_perc` | Gauge | GPU KV cache utilization |
| `kserve_vllm:request_success_total` | Counter | Success/error counts by `model_name`, `finished_reason` |

### 7. OpenTelemetry Span Metrics

The OTel Collector's `spanmetrics` connector converts distributed traces into RED metrics:
- Request rate, error rate, duration histogram
- Dimensions: `http.method`, `http.status_code`, `http.route`, `rpc.method`
- Exemplars linking metrics back to traces

## Dashboards

### Deployed Dashboards (Grafana Operator CRs)

| Dashboard | File | Description | Data Sources |
|-----------|------|-------------|--------------|
| **Platform Overview** | `platform-overview.json` | Authorized/limited requests, rejection ratio, error rates, active connections | Limitador, Istio |
| **Subscription Usage** | `subscription-usage.json` | Per-subscription request and token breakdown, rejection rates, latency by model | Limitador native (`subscription`, `model`, `limit_name` labels), Istio, vLLM |
| **vLLM Metrics** | `vllm-metrics.json` | Model latency, KV cache, GPU utilization, error rates | vLLM PodMonitor |
| **Gateway Infrastructure** | `gateway-infrastructure.json` | Gateway health, routes, policies, resource usage | gateway-api-state-metrics, container metrics |

### Comparison with RHCL 1.3 Reference Dashboards

RHCL 1.3 / upstream Kuadrant provide reference dashboards on [Grafana.com](https://grafana.com):

| RHCL Dashboard | Grafana ID | Persona | Our Equivalent |
|----------------|------------|---------|----------------|
| **Platform Engineer** | 20982 | Infrastructure operator | **Platform Overview** + **Gateway Infrastructure** (combined coverage) |
| **App Developer** | 21538 | Application teams | **Tier Usage** + **vLLM Metrics** (model-focused) |
| **Business User** | 20981 | Stakeholders | No direct equivalent (see Gap Analysis) |
| **DNS Operator** | 22695 | DNS operations | N/A (no DNSPolicy in our setup) |

Our dashboards are purpose-built for the MaaS use case rather than generic Kuadrant dashboards. They cover the same underlying metrics but organize panels around MaaS-specific concerns (rate limiting tiers, model serving SLOs, token budgets).

## Alerts (PrometheusRules)

### Deployed Alert Rules

**Rate Limiting Health** (`maas-alerts` in `kuadrant-system`):
| Alert | Expression | Severity | For |
|-------|-----------|----------|-----|
| `MaaSLimitadorDown` | `limitador_up == 0` | critical | 1m |
| `MaaSHighRejectionRate` | rejection ratio > 30% | warning | 5m |
| `MaaSDatastorePartitioned` | `datastore_partitioned == 1` | critical | 1m |

**Gateway Errors** (`maas-gateway-alerts` in `openshift-ingress`):
| Alert | Expression | Severity | For |
|-------|-----------|----------|-----|
| `MaaSGatewayAuthTimeout` | `kuadrant_errors > 0` | warning | 2m |
| `MaaSBackend5xx` | 5xx from backend via gateway | warning | 2m |
| `MaaSGatewayErrorsCritical` | total error rate > 5% | critical | 5m |

**vLLM SLOs** (`maas-vllm-slo` in model namespace):
| Alert | Expression | Severity | For |
|-------|-----------|----------|-----|
| `MaaSHighP99Latency` | P99 > 30s | warning | 5m |
| `MaaSKVCacheNearFull` | GPU cache > 90% | warning | 5m |
| `MaaSHighErrorRate` | vLLM errors > 0 | critical | 5m |

### Comparison with RHCL 1.3 Reference Alerts

RHCL 1.3 recommends several alert categories:

| RHCL Alert Category | Our Coverage | Notes |
|---------------------|--------------|-------|
| **Gateway health** (`UnhealthyGateway`) | Partial | We alert on gateway errors but not on Gateway API status conditions. Could add using `gatewayapi_gateway_status` |
| **Insecure listeners** (`InsecureHTTPListener`) | Not needed | All our listeners are HTTPS (TLS passthrough) |
| **Missing policies** (`HTTPRouteWithoutAuthPolicy`, etc.) | Not implemented | Useful for drift detection — low priority for us since ArgoCD manages policy lifecycle |
| **SLO burn rates** (multi-window, multi-burn-rate) | Different approach | RHCL uses Sloth-generated SLO alerts; we use simpler threshold alerts on vLLM. Consider adopting burn-rate model if SLO precision matters |
| **Limitador health** | Covered | `MaaSLimitadorDown`, `MaaSDatastorePartitioned` |
| **Rate limit saturation** | Covered | `MaaSHighRejectionRate` |

## Tracing

### Deployed Stack

| Component | CR | Namespace | Purpose |
|-----------|-----|-----------|---------|
| Tempo | `TempoMonolithic` | observability | Trace storage (PV, 48h retention) |
| OTel Collector | `OpenTelemetryCollector` | observability | OTLP receiver → Tempo exporter + spanmetrics |
| Grafana Datasource | `GrafanaDataSource` | observability | Tempo querying + traces-to-metrics correlation |

### Comparison with RHCL 1.3 Tracing

RHCL 1.3 supports native tracing in:
- **Authorino** (auth decisions)
- **Limitador** (rate limit checks)
- **Wasm-shim** (Envoy filter, policy evaluation)
- **Kuadrant operator** (reconciliation loops)

Configuration is centralized via the Kuadrant CR:
```yaml
spec:
  observability:
    tracing:
      defaultEndpoint: rpc://tempo-tempo.observability.svc:4317
      insecure: true
```

> **Gap:** We deploy the trace infrastructure (Tempo + OTel Collector) but do NOT configure Kuadrant's native tracing. The data plane components (Authorino, Limitador, wasm-shim) are not sending traces. See Gap Analysis below.

## Gap Analysis: RHCL 1.3 vs Our Implementation

### What We Have (and RHCL 1.3 validates)

1. **Limitador metrics + ServiceMonitor** — RHCL 1.3 baseline
2. **Istio/Envoy metrics** — standard data plane observability
3. **gateway-api-state-metrics** — RHCL 1.3 recommended approach for Gateway API resource visibility
4. **Custom Grafana dashboards** — RHCL 1.3 recommends dashboards per persona
5. **PrometheusRules for rate limiting and gateway health** — aligned with RHCL guidance
6. **TelemetryPolicy** — custom label enrichment for model/user attribution
7. **vLLM-specific monitoring** — PodMonitor + SLO alerts (beyond RHCL scope, MaaS-specific)
8. **Distributed tracing infrastructure** — Tempo + OTel Collector (RHCL recommends Jaeger/Tempo)

### Gaps to Address

| # | Gap | Priority | Effort | Description |
|---|-----|----------|--------|-------------|
| 1 | **Kuadrant native tracing not configured** | Medium | Low | Set `observability.tracing.defaultEndpoint` in Kuadrant CR to send Authorino/Limitador/wasm-shim traces to our Tempo instance. Blocked if RHOAI operator manages the Kuadrant CR directly |
| 2 | **No Gateway status condition alerts** | Low | Low | Add `UnhealthyGateway` alert using `gatewayapi_gateway_status{type="Programmed"} == 0`. The metric is already being scraped |
| 3 | **Missing route types in ConfigMap** | Low | Low | Upstream covers TLSRoute, TCPRoute, UDPRoute, BackendTLSPolicy. We only need these if the setup expands beyond HTTP/gRPC |
| 4 | **No Authorino ServiceMonitor** | Low | Low | RHCL documents scraping Authorino auth server metrics. Check if the Kuadrant operator creates one automatically; if not, add it |
| 5 | **No business-user dashboard** | Low | Medium | RHCL provides a "Business User" dashboard (Grafana ID 20981). Could adapt it for MaaS token consumption reporting |
| 6 | **No Kuadrant operator metrics** | Low | Low | Set `observability.enable: true` in Kuadrant CR for `kuadrant_policies_total` and `kuadrant_ready` metrics. Same blocker as gap #1 |
| 7 | **SLO alerts use thresholds, not burn rates** | Low | Medium | RHCL uses Sloth-generated multi-window multi-burn-rate alerts. Our threshold-based approach is simpler but less precise for SLO compliance tracking |

### Intentional Omissions

| Item | Reason |
|------|--------|
| **DNSPolicy dashboard/alerts** | No DNSPolicy in our setup (no external DNS management) |
| **Envoy access logs** | Not needed — traces + metrics cover our use case. Access logs add storage cost without proportional value |
| **Missing-policy alerts** | ArgoCD `selfHeal` ensures policies are always present. Drift detection via alerts is redundant |
| **`InsecureHTTPListener` alert** | All listeners are HTTPS by design (TLS passthrough from OpenShift Route) |

## Configuration Reference

### values.yaml Keys (maas-platform)

```yaml
telemetry:
  enabled: true          # TelemetryPolicy for custom metric labels

monitoring:
  enabled: true          # ServiceMonitor for Limitador
  scrapeInterval: 30s
  vllm:
    enabled: true        # PodMonitor for vLLM + SLO alerts
    modelNamespace: maas-models
  gatewayMetrics:
    enabled: true        # gateway-api-state-metrics deployment
    namespace: observability

alerting:
  enabled: true          # PrometheusRules
  rejectionRateThreshold: 0.3  # 30% rejection triggers warning

grafana:
  enabled: false         # GrafanaDashboard CRs (requires Grafana Operator)
  instanceSelector:
    dashboards: "grafana"
```

### Enabling Full Observability

```bash
# Deploy with Grafana dashboards
make deploy-maas GRAFANA_ENABLED=true

# Or via ArgoCD values
modules:
  maas:
    enabled: true
  observability:
    enabled: true
```

## References

- [RHCL 1.3 Observability](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/observability/rhcl-observability)
- [Kuadrant Observability — Metrics](https://docs.kuadrant.io/latest/kuadrant-operator/doc/observability/metrics/)
- [Kuadrant Observability — Tracing](https://docs.kuadrant.io/latest/kuadrant-operator/doc/observability/tracing/)
- [Kuadrant Observability — Dashboards & Alerts](https://docs.kuadrant.io/latest/kuadrant-operator/doc/observability/examples/)
- [Kuadrant Token Metrics Monitoring](https://docs.kuadrant.io/1.3.x/kuadrant-operator/doc/user-guides/observability/token-metrics/)
- [gateway-api-state-metrics](https://github.com/Kuadrant/gateway-api-state-metrics)
- [Authorino Observability](https://docs.kuadrant.io/latest/authorino/docs/user-guides/observability/)
