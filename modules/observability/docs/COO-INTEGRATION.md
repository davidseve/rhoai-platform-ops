# Cluster Observability Operator (COO) Integration

Deployment guide for the RHOAI-managed observability stack via COO. See [ADR-0013](../../../docs/adr/0013-coo-observability-migration.md) for the migration decision.

**Status**: Implemented (gated behind `coo.enabled: false` by default -- Technology Preview in RHOAI 3.4).

## What COO Provides

When `coo.enabled: true` is set in the operators chart:

1. **COO Subscription** -- installs the Cluster Observability Operator in `openshift-operators`
2. **DSCI monitoring** -- patches `default-dsci` with `spec.monitoring.managementState: Managed`, which deploys in `redhat-ods-monitoring`:
   - Prometheus + Alertmanager (via COO MonitoringStack)
   - OTel Collector (RHOAI-managed)
   - Tempo (trace storage)
   - Thanos Querier (federated query)
3. **UIPlugins** -- OpenShift Console extensions:
   - `monitoring` (Perses dashboards -- Dev Preview)
   - `troubleshooting-panel` (Korrel8r signal correlation -- GA)
   - `distributed-tracing` (native trace UI -- GA)

## Architecture

```
┌─────────────────────────────────────────────────┐
│ RHOAI-managed (redhat-ods-monitoring)           │
│  Prometheus + Alertmanager + Thanos Querier     │
│  Tempo (replaces our TempoMonolithic)           │
│  OTel Collector (RHOAI, not configurable)       │
└─────────────────────────────────────────────────┘
         ▲                          ▲
         │ traces                   │ query
┌────────┴────────┐         ┌──────┴───────┐
│ Our OTel        │         │ Our Grafana  │
│ Collector       │         │ (6 dashboards│
│ (spanmetrics)   │         │  + Thanos)   │
└─────────────────┘         └──────────────┘
```

**What we keep:**
- Grafana Operator + instance + 6 dashboards (4 MaaS + 2 tracing)
- OTel Collector with spanmetrics connector (RHOAI collector is not configurable)
- PrometheusRule `tracing-slo` (3 alerts from spanmetrics)
- ServiceMonitor for OTel Collector
- OTel and Tempo Operator Subscriptions (prerequisites for RHOAI)

**What we replaced:**
- TempoMonolithic CR (now gated behind `{{- if not .Values.coo.enabled }}`)
- OTel Collector exports to RHOAI Tempo instead of local Tempo
- Grafana Tempo datasource points to RHOAI Tempo query-frontend

## Enabling COO

### Operators chart

```bash
helm upgrade obs-operators modules/observability/charts/operators/ \
  --set coo.enabled=true
```

Or in ArgoCD `apps/values.yaml`, override the operators chart values.

### Tracing chart

```bash
helm upgrade obs-tracing modules/observability/charts/tracing/ \
  --set coo.enabled=true
```

### Grafana chart

```bash
helm upgrade obs-grafana modules/observability/charts/grafana/ \
  --set coo.enabled=true
```

### Verify

After enabling, verify RHOAI creates resources in `redhat-ods-monitoring`:

```bash
oc get pods -n redhat-ods-monitoring
# Expected: prometheus-*, alertmanager-*, thanos-querier-*, collector-*, tempo-*
```

The Tempo service is `tempo-data-science-tempomonolithic-gateway` in `redhat-ods-monitoring`, exposing both OTLP gRPC (`:4317`) and HTTP query (`:3200`).

## Running Tests

```bash
# With COO enabled
COO_ENABLED=true make test-observability
```

The `COO_ENABLED` env var adjusts test assertions for Tempo pod location and datasource URLs.

## Rollback

To revert to the standalone stack:

1. Set `coo.enabled: false` in all three charts
2. The TempoMonolithic CR will be re-deployed
3. OTel Collector reverts to the local Tempo endpoint
4. Grafana datasource reverts to local Tempo URL

## Key Metrics (available once enabled)

### Gateway / Governance metrics (from Kuadrant + MaaS controller)

| Metric | Type | Labels | Use Case |
|--------|------|--------|----------|
| `authorized_hits` | counter | user, subscription, model | Billing/cost -- total tokens consumed |
| `authorized_calls` | counter | user, subscription | Capacity planning -- API calls allowed |
| `limited_calls` | counter | user, subscription | Rate limit monitoring -- requests denied |

### RHOAI Dashboard

With `observabilityDashboard: true` in OdhDashboardConfig, the RHOAI Dashboard shows an **Observe and Monitor** tab with built-in token consumption panels.

## Known Issues

- **DSCI monitoring is Technology Preview** in RHOAI 3.4 -- API may change in 3.5
- **TelemetryPolicy CEL incompatibility** -- `responseBodyJSON("/model")` and `auth.identity.selected_subscription` are WASM expressions, not valid Authorino CEL. Per-model metric labels unavailable until Kuadrant resolves this
- **Tempo service name** -- not explicitly documented; must verify on cluster after enabling DSCI monitoring

## References

- [RHOAI 3.4 Managing Observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-observability_managing-rhoai)
- [COO UIPlugins](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html/ui_plugins_for_red_hat_openshift_cluster_observability_operator/perses-dashboard)
- [ADR-0013: COO Migration](../../../docs/adr/0013-coo-observability-migration.md)
- [ADR-0003: Grafana Operator](../../../docs/adr/0003-grafana-operator.md)
