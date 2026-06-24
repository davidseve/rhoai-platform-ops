# ADR-0013: Cluster Observability Operator Migration

## Status

Accepted

## Context

Our observability module (`modules/observability/`) deploys three custom components:

1. **TempoMonolithic** CR in `observability` namespace (trace storage)
2. **OTel Collector** CR in `observability` namespace (trace collection + spanmetrics)
3. **Grafana Operator** + Grafana instance with 6 dashboards (4 MaaS + 2 tracing)

RHOAI 3.4 introduced a centralized observability stack (Technology Preview) managed via the `DataScienceClusterInitialization` (DSCI) CR. When `spec.monitoring.managementState: Managed` is set, RHOAI deploys a full stack in `redhat-ods-monitoring`:

- Prometheus + Alertmanager (via COO MonitoringStack)
- OTel Collector (RHOAI-managed, not configurable)
- Tempo (trace backend)
- Thanos Querier (federated query)

This creates overlap with our custom Tempo and OTel Collector. Additionally, COO provides UIPlugins for the OpenShift Console (Perses dashboards, Korrel8r troubleshooting, distributed tracing) and enables the `observabilityDashboard` in the RHOAI Dashboard.

The question: adopt COO now (TP) or wait for GA?

## Options Considered

### Option 1: Wait for GA
- **Pros:** Production-supported, stable API, lower risk
- **Cons:** Delays native RHOAI observability features (showback dashboards, console tracing UI, Korrel8r), blocks `observabilityDashboard` flag

### Option 2: Add COO alongside existing stack (duplication)
- **Pros:** Zero disruption, easy rollback
- **Cons:** Duplicate Tempo instances, duplicate OTel Collectors, wasted resources, confusing architecture

### Option 3: Migrate to COO, replace Tempo, keep Grafana + OTel Collector (chosen)
- **Pros:** No duplication, native RHOAI features enabled, spanmetrics preserved, custom dashboards preserved, clean rollback path
- **Cons:** TP risk (API may change in 3.5), Tempo service name must be verified on cluster

## Decision

**Option 3**: Migrate to the RHOAI-managed stack with selective component replacement.

- **Remove** our TempoMonolithic CR (replaced by RHOAI Tempo in `redhat-ods-monitoring`)
- **Redirect** our OTel Collector to export traces to RHOAI Tempo (keep collector for spanmetrics connector -- RHOAI collector is not configurable)
- **Keep** Grafana for custom MaaS dashboards (Perses is Dev Preview, cannot replace 6 JSON dashboards)
- **Keep** OTel/Tempo Operator Subscriptions (prerequisites for RHOAI)
- **Add** COO Subscription, DSCI monitoring config, UIPlugins, `observabilityDashboard: true`
- **Gate** everything behind `coo.enabled: false` (default off) for safe rollback

The TP risk is acceptable because:
1. All changes are gated behind a feature flag
2. Rollback is straightforward: disable flag, re-add TempoMonolithic, revert endpoints
3. COO itself (MonitoringStack, UIPlugins) is GA -- only the DSCI integration is TP
4. We gain immediate access to native showback dashboards and console tracing

## Consequences

### Positive
- Native RHOAI observability: `Observe & Monitor` tab in RHOAI Dashboard
- UIPlugins: Perses dashboards, Korrel8r troubleshooting, distributed tracing in OpenShift Console
- No duplicate Tempo instances
- Grafana Tempo datasource points to RHOAI-managed Tempo (single trace backend)

### Negative
- TP dependency: DSCI `spec.monitoring` API may change in RHOAI 3.5
- Tempo service name for RHOAI stack not explicitly documented (must verify on cluster)
- Spanmetrics remain on our custom OTel Collector (RHOAI collector not configurable)

## References

- [RHOAI 3.4 Managing Observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-observability_managing-rhoai)
- [COO UIPlugins](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html/ui_plugins_for_red_hat_openshift_cluster_observability_operator/perses-dashboard)
- [ADR-0003: Grafana Operator](0003-grafana-operator.md) -- Grafana retained for custom dashboards
- [ADR-0004: Tracing Stack](0004-tracing-stack.md) -- OTel + Tempo choice unchanged (operators kept)
