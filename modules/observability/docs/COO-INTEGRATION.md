# Cluster Observability Operator (COO) Integration

Implementation guide for deploying COO to enable native RHOAI observability dashboards and showback metrics.

**When to implement**: When the RHOAI observability stack moves to GA (estimated 3.5+).

**Impact**: Enables `observabilityDashboard: true` in OdhDashboardConfig, providing built-in token consumption panels in the RHOAI Dashboard without requiring Grafana.

## Prerequisites

Three things must be in place before COO adds value:

1. **User Workload Monitoring enabled** — already done (declarative ConfigMap in `modules/observability/charts/operators/`)
2. **Kuadrant observability enabled** — `spec.observability.enable: true` on the Kuadrant CR (currently NOT set)
3. **COO + OpenTelemetry Operator installed** — COO provides PersesDashboard, UIPlugins, Korrel8r. OpenTelemetry Operator already deployed via `modules/observability/charts/operators/`.

## Configuration Steps

### 1. Install Cluster Observability Operator

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

Add to `modules/observability/charts/operators/templates/`.

### 2. Enable Kuadrant Observability

Patch the Kuadrant CR in `kuadrant-system`:

```yaml
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
spec:
  observability:
    enable: true
```

This enables the MaaS-specific metrics from the gateway (authorized_hits, authorized_calls, limited_calls).

### 3. Enable OdhDashboardConfig flag

In `modules/maas/charts/maas-platform/values.yaml`:

```yaml
dashboard:
  observabilityDashboard: true  # currently false
```

This activates the Observability tab in the RHOAI Dashboard.

### 4. Enable Tenant Telemetry

The Tenant CR (`default-tenant` in `models-as-a-service`) must have:

```yaml
spec:
  telemetry:
    enabled: true
```

The maas-controller then auto-creates:
- `TelemetryPolicy` — defines metrics labels for gateway traffic
- `Istio Telemetry` — configures metric collection on the data plane

Already enabled via Helm template (ArgoCD SSA).

## Key Metrics (available once enabled)

### Gateway / Governance metrics (from Kuadrant + MaaS controller)

| Metric | Type | Labels | Use Case |
|--------|------|--------|----------|
| `authorized_hits` | counter | user, subscription, model | **Billing/cost** — total tokens consumed (input + output) |
| `authorized_calls` | counter | user, subscription | Capacity planning — number of API calls allowed |
| `limited_calls` | counter | user, subscription | Rate limit monitoring — requests denied |
| `istio_request_duration_milliseconds_bucket` | histogram | subscription | SLA tracking — per-subscription gateway latency (P50/P95/P99) |

### vLLM inference metrics (already collected via PodMonitor)

| Metric | Use Case |
|--------|----------|
| `vllm:e2e_request_latency_seconds` | End-to-end inference latency |
| `vllm:time_to_first_token_seconds` | TTFT for streaming quality |
| `vllm:kv_cache_usage_perc` | Memory pressure indicator |
| `vllm:num_requests_running` / `waiting` | Queue depth / saturation |

### Chargeback

For billing/cost attribution, focus on `authorized_hits`:
- Per-user, per-model token counts
- Feed into pricing pipeline with custom $/token logic
- Labels provide `user`, `subscription`, `model` dimensions

## Compatibility with Existing Stack

COO does NOT conflict with the current observability infrastructure:

| Component | Current | With COO | Conflict? |
|-----------|---------|----------|-----------|
| Grafana Operator | Community v5 | Unchanged | No |
| OpenTelemetry Operator | Red Hat build | Unchanged | No |
| Tempo Operator | Red Hat build | Unchanged | No |
| User Workload Monitoring | Enabled | Required by COO | No |
| PersesDashboard | N/A | Provided by COO | No |
| UIPlugins (tracing, troubleshooting) | N/A | Provided by COO | No |
| Korrel8r (incident detection) | N/A | Provided by COO | No |

COO adds native OpenShift Console dashboards alongside Grafana (complementary, not replacement).

## Implementation Checklist

When ready to implement:

- [ ] Verify COO is GA in the target RHOAI version (check release notes)
- [ ] Add COO Subscription to `modules/observability/charts/operators/`
- [ ] Add `spec.observability.enable: true` to Kuadrant CR in `modules/maas/charts/operators/`
- [ ] Set `observabilityDashboard: true` in `maas-platform/values.yaml`
- [ ] Verify TelemetryPolicy CEL incompatibility is resolved (per-model labels)
- [ ] Validate `authorized_hits` metric is populated in Prometheus
- [ ] Create showback dashboard (tokens per user per model per day)
- [ ] Add E2E tests: COO operator health, UIPlugin availability, metric existence
- [ ] Update `scripts/cluster-cleanup.sh` (COO Subscription removal)
- [ ] Consider EvalHub OTel logs — COO may provide a log backend (UIPlugin for logging)

## Known Issues

- **TelemetryPolicy CEL incompatibility**: `responseBodyJSON("/model")` and `auth.identity.selected_subscription` are WASM expressions, not valid Authorino CEL. Limitador metrics lack `model`, `subscription`, `organization_id`, `cost_center` labels until Kuadrant separates WASM and Authorino expression evaluation. Re-evaluate in RHOAI 3.5+.
- **EvalHub OTel logs**: No log backend today (Loki/Vector not deployed). COO with logging UIPlugin could provide this. `enableLogs: false` in EvalHub CR until backend is available.

## References

- **Setup guide**: https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/observability/setup.md
- **Metrics reference**: https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/observability/metrics-and-dashboards.md
- **COO product docs**: https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/cluster_observability_operator/
- **RHOAI Observability**: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-observability_managing-rhoai
- **ADR-0003**: Grafana Operator choice with COO migration path
- **Roadmap Phase 6**: COO Native Showback Dashboards
