# Observability Module

Deploys Grafana Operator, a Grafana instance with OpenShift OAuth proxy, and connects it to OpenShift User Workload Monitoring (Thanos Querier) for platform-wide metrics visualization.

## Architecture

The module has two parts:

**Part A -- Observability infrastructure** (`modules/observability/`):
- Grafana Operator subscription (community-operators, channel v5, in `openshift-operators`)
- `observability` namespace for the Grafana instance
- User Workload Monitoring enablement (`cluster-monitoring-config` ConfigMap)
- Grafana CR with OpenShift OAuth proxy sidecar (reencrypt Route)
- ServiceAccount + long-lived token Secret for Thanos Querier auth
- ClusterRoleBinding to `cluster-monitoring-view`
- GrafanaDatasource pointing to Thanos Querier

**Part B -- MaaS metric extensions** (`modules/maas/charts/maas-platform/`):
- PodMonitor for vLLM pods (TLS-aware via service-ca CA bundle)
- PrometheusRule with SLO alerts (latency, KV cache, error rate)
- Three GrafanaDashboard CRs (platform overview, vLLM metrics, per-tier usage)

Part B resources are split into two independent guards:
- `monitoring.vllm.enabled` (default: `true`): PodMonitor + PrometheusRule -- always active, no Grafana dependency
- `grafana.enabled` (default: `false`): GrafanaDashboard CRs -- opt-in, requires Grafana Operator CRDs

## Authentication Flow

```
User -> Route (reencrypt TLS) -> OAuth Proxy (port 9091)
  -> validates token with OpenShift API
  -> proxies to Grafana (port 3000)

Grafana -> GrafanaDatasource
  -> Bearer token from grafana-sa-token Secret
  -> Thanos Querier (port 9091, openshift-monitoring)
  -> queries all UWM Prometheus data
```

The OAuth proxy uses `openshift-sar` to enforce that only users who can `get` the Grafana Route in the `observability` namespace can access the UI.

## vLLM TLS Scraping

vLLM pods serve metrics over HTTPS (TLS cert at `/var/run/kserve/tls/` signed by OpenShift service-ca). The PodMonitor uses:

1. A ConfigMap annotated with `service.beta.openshift.io/inject-cabundle: "true"` in the model namespace -- the service-ca operator auto-populates it with the cluster CA bundle
2. `tlsConfig.ca.configMap` in the PodMonitor referencing this CA bundle

No `insecureSkipVerify` -- proper certificate validation against the OpenShift service-ca.

## Metric Contract

vLLM metric names used in dashboards and alerts (prefix `vllm:`):
- `vllm:generation_tokens_total`
- `vllm:prompt_tokens_total`
- `vllm:e2e_request_latency_seconds_bucket`
- `vllm:time_to_first_token_seconds_bucket`
- `vllm:time_per_output_token_seconds_bucket`
- `vllm:num_requests_running` / `waiting` / `swapped`
- `vllm:gpu_cache_usage_perc` / `cpu_cache_usage_perc`
- `vllm:request_success_total`

Metric names may change between vLLM versions. The E2E test `test_02_datasource.py::test_vllm_metrics_discoverable` queries actual metrics from Thanos at deploy time to catch mismatches early.

## Deployment

```bash
# Observability only
make deploy-observability

# Full stack (observability + MaaS with dashboards)
make deploy-all

# MaaS without dashboards (monitoring still active)
make deploy-maas

# MaaS with dashboards (requires observability deployed first)
make deploy-maas GRAFANA_ENABLED=true
```

## Grafana Operator Upgrades

The operator subscription uses channel `v5` with `Automatic` installPlanApproval. When upgrading:

1. Check [Grafana Operator release notes](https://github.com/grafana/grafana-operator/releases) for CRD changes
2. Verify dashboard JSON compatibility
3. Test in a staging cluster before production
4. The E2E tests validate operator health, datasource connectivity, and dashboard existence

## Cleanup

```bash
make cluster-cleanup-observability   # Remove only observability resources
make cluster-cleanup                 # Remove everything
```
