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

vLLM metric names used in dashboards and alerts (prefix `kserve_vllm:`):
- `kserve_vllm:generation_tokens_total`
- `kserve_vllm:prompt_tokens_total`
- `kserve_vllm:e2e_request_latency_seconds_bucket`
- `kserve_vllm:time_to_first_token_seconds_bucket`
- `kserve_vllm:time_per_output_token_seconds_bucket`
- `kserve_vllm:num_requests_running` / `waiting` / `swapped`
- `kserve_vllm:gpu_cache_usage_perc` / `cpu_cache_usage_perc`
- `kserve_vllm:request_success_total`

The `kserve_vllm:` prefix is applied by KServe when it wraps vLLM. Metric names may change between vLLM/KServe versions. The E2E test `test_02_datasource.py::test_vllm_metrics_discoverable` queries actual metrics from Thanos at deploy time to catch mismatches early.

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

## Distributed Tracing

The module includes distributed tracing via Red Hat build of OpenTelemetry and Red Hat build of Tempo.

### Architecture

```
vLLM pods (OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)
  -> OTel Collector (OTLP gRPC :4317, observability namespace)
     -> Tempo (TempoMonolithic, memory backend)
     -> spanmetrics connector -> Prometheus (span-derived RED metrics)

Grafana -> Tempo datasource (HTTP :3200) for trace exploration
```

### Components

- **TempoMonolithic CR** (`tempo.grafana.com/v1alpha1`): trace storage with memory backend (configurable to PV). OTLP gRPC + HTTP ingestion enabled.
- **OpenTelemetryCollector CR** (`opentelemetry.io/v1beta1`): receives OTLP traces, exports to Tempo, derives span metrics via `spanmetrics` connector.
- **ServiceMonitor**: scrapes OTel Collector Prometheus endpoint for span-derived metrics.
- **Tempo GrafanaDatasource**: connects Grafana to Tempo for trace exploration with service map and node graph.
- **Traces Dashboard**: service map, latency distribution (from spanmetrics), recent traces table, request rate by service.

### vLLM Tracing

Tracing on model pods is opt-in (`tracing.enabled: false` by default in `maas-model/values.yaml`). When enabled, the following env vars are set on the vLLM container:

- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`: points to the OTel Collector (`http://maas-collector-collector.observability.svc:4317`)
- `OTEL_SERVICE_NAME`: defaults to the model's `servedName`
- `OTEL_TRACES_EXPORTER`: `otlp`

**Risk**: The current CPU image (`vllm-cpu-openai-ubi9:0.3`) may lack OTEL Python packages. Tracing will only produce spans once a vLLM image with OTEL dependencies is deployed.

### Operators

- **Red Hat build of OpenTelemetry**: `opentelemetry-product` subscription in `openshift-opentelemetry-operator` namespace (channel `stable`, `redhat-operators`)
- **Red Hat build of Tempo**: `tempo-product` subscription in `openshift-tempo-operator` namespace (channel `stable`, `redhat-operators`)

See [ADR-0004](../../../docs/adr/0004-tracing-stack.md) for the decision rationale.

## Alerting

Two PrometheusRule resources define the alert rules:

### Gateway alerts (`maas-alerts` in `kuadrant-system`)

| Alert | Severity | Condition | Meaning |
|-------|----------|-----------|---------|
| MaaSLimitadorDown | critical | `limitador_up == 0` for 1m | Rate limiter is completely down |
| MaaSHighRejectionRate | warning | Rejection ratio > 30% for 5m | Rate limits are rejecting a large fraction of traffic |
| MaaSDatastorePartitioned | critical | `datastore_partitioned == 1` for 1m | Limitador lost its backing store |
| MaaSGatewayErrors | warning | Any `kuadrant_errors` for 2m | WASM auth timeout -- auth evaluation exceeded 200ms |
| MaaSGatewayErrorsCritical | critical | Error ratio > 5% for 5m | Sustained gateway error rate -- auth service cannot respond in time |

### vLLM SLO alerts (`maas-vllm-slo` in `maas-models`)

| Alert | Severity | Condition | Meaning |
|-------|----------|-----------|---------|
| MaaSHighP99Latency | warning | P99 e2e latency > 30s for 5m | Model inference is too slow |
| MaaSKVCacheNearFull | warning | KV cache > 90% for 5m | Model is approaching memory limits |
| MaaSHighErrorRate | critical | vLLM error rate > 0 for 5m | Model is returning inference errors |

## Production Considerations

### Gateway 5xx errors

Gateway 5xx errors come from the **Kuadrant WASM filter** in Envoy, not from vLLM or Authorino directly. The WASM plugin's `auth-service` timeout is hardcoded to **200ms** by the Kuadrant operator. When auth evaluation (TokenReview + tier lookup) exceeds 200ms under concurrent load, the WASM filter times out and returns 500 (`failureMode: deny`). Authorino itself succeeds, but the WASM filter has already given up.

**Key metrics**:
- `kuadrant_errors` -- WASM filter error count (scraped from Envoy gateway pod, available in Prometheus/Thanos)
- `kuadrant_allowed` / `kuadrant_denied` -- successful and rate-limited requests for context
- Note: `haproxy_server_http_responses_total` does NOT work for MaaS because the `maas-default-gateway` route is **passthrough** (HAProxy can't see HTTP status codes)

**Root cause**: The 200ms WASM auth timeout is not configurable via AuthPolicy or WasmPlugin (Kuadrant operator reconciles it back). With `CONCURRENCY=2` all requests pass; with `CONCURRENCY>=4` roughly 50% fail.

**Mitigations**:
- Keep client concurrency within what the auth chain can handle in 200ms
- Ensure Authorino has adequate CPU/memory so auth completes quickly
- AuthPolicy cache TTLs reduce repeated auth calls (identity: 600s, tier: 300s, authorization: 60s)
- Client-side retry with exponential backoff for transient 500s
- **Upstream fix needed**: Kuadrant should make the WASM auth-service timeout configurable

### Trace pipeline (port-forward vs in-cluster)

The `generate-traffic.sh` script uses `oc port-forward` to reach the OTel Collector from outside the cluster. This is dev-only tooling. In production, application pods emit traces directly to the collector service (`maas-collector-collector.observability.svc:4317`) from within the cluster.

## Cleanup

```bash
make cluster-cleanup-observability   # Remove only observability resources
make cluster-cleanup                 # Remove everything
```
