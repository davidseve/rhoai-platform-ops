# Phase 2b: Traceability Enhancements -- Implementation Plan

Stretch goals deferred from Phase 2. See [ADR-0004](adr/0004-tracing-stack.md) for context.

## Current State (updated 2026-04-30)

The Phase 2 tracing infrastructure is fully deployed and functional:

- OTel Collector with `spanmetrics` connector in `observability` namespace
- TempoMonolithic with memory backend
- Tempo Grafana datasource (deterministic `uid: tempo`) + Trace Exploration + Trace Search dashboards
- vLLM tracing via `--otlp-traces-endpoint` CLI arg (env vars are ignored in vLLM v0.7.3)
- Custom vLLM CPU image with OTel packages: `quay.io/dseveria/vllm-cpu-openai-ubi9:0.3-otel`
- Token-level tracing opt-in via `--collect-detailed-traces request`
- E2E tracing tests gated behind `--run-tracing` flag

**Blocker resolved**: Task 1 (vLLM OTEL image) is complete. Tasks 1 and 4 are done.

## Dependency Graph

```
Task 1: vLLM OTEL Image (BLOCKER)
  ├── Task 2: Gateway Tracing
  ├── Task 4: Token-Level Tracing
  └── Task 5: Trace SLO Alerts
Task 3: Persistent Tempo (independent, parallel with Task 1)
  └── Task 5: Trace SLO Alerts (benefits from persistent storage)
```

Task 3 is independent and can be done in parallel with Task 1. Tasks 2, 4, and 5 depend on Task 1 (the OTEL image blocker). Task 5 benefits from all others being complete but only strictly requires spanmetrics data flowing (Task 1 + collector already configured).

---

## Task 1: vLLM CPU Image with OpenTelemetry -- DONE

**Context**: Upstream vLLM merged [PR #34466](https://github.com/vllm-project/vllm/pull/34466) (Feb 2026) adding OTel to `requirements/common.txt`. The existing CPU image is built from a pinned fork commit (`RHRolun/vllm@94ad14587`) and installs `requirements-cpu.txt` + `requirements-common.txt` but the pinned commit predates the OTel addition. The upstream [Containerfile](https://github.com/rh-aiservices-bu/llm-on-openshift/blob/main/llm-servers/vllm/cpu/Containerfile) does not add OTel separately.

### Approach -- two options (recommend Option A)

- **Option A -- Extend the existing Containerfile**: Add a `RUN pip install` layer for the four OTel packages after the vLLM wheel install. Publish as `vllm-cpu-openai-ubi9:0.3-otel` (or `:0.4`) to a project-controlled quay.io repo. Minimal delta, preserves known-good vLLM version.
- **Option B -- Bump the fork to post-PR#34466 vLLM**: Update the git checkout to a commit that includes OTel in `requirements/common.txt`. Higher risk of regressions; requires re-validating CPU compilation.

### Implementation (Option A)

1. Create `modules/maas/images/vllm-cpu-otel/Containerfile` -- `FROM quay.io/rh-aiservices-bu/vllm-cpu-openai-ubi9:0.3` plus `pip install` of OTel packages
2. Add a `make build-vllm-cpu-otel` Makefile target
3. Update `modules/maas/charts/maas-model/values.yaml` `images.vllm` to the new image
4. Document in OBSERVABILITY.md and ADR-0004

**OTel packages to install:**

```
opentelemetry-sdk>=1.26.0
opentelemetry-api>=1.26.0
opentelemetry-exporter-otlp>=1.26.0
opentelemetry-semantic-conventions-ai>=0.4.1
```

### Validation

Set `tracing.enabled: true`, deploy model, send inference request, query Tempo API for traces. The existing `test_03_tracing.py::test_traces_visible_after_inference` (with `--run-tracing`) covers this.

---

## Task 2: Gateway/Envoy Distributed Tracing -- DEFERRED to RHOAI 3.4

> **Status (2026-04-30)**: Deferred. The original approach was incorrect and no viable short-term alternative exists. Re-evaluate when RHOAI 3.4 ships.

**Original approach (INCORRECT)**: The plan proposed `EnvoyExtensionPolicy` from `extensions.kuadrant.io/v1alpha1`. This API belongs to the **Envoy Gateway** project, NOT to the Istio/OSSM stack. The `openshift-default` GatewayClass uses Envoy managed by Istio via the cluster-ingress-operator — a completely different data plane.

### Investigation findings (2026-04-30)

1. **Istio CR is managed**: The cluster-ingress-operator reconciles the Istio CR for `openshift-default`. Adding `extensionProviders` for OpenTelemetry is not supported — the operator overwrites custom changes.

2. **Istio Telemetry API requires extensionProviders**: The `Telemetry` CR (`telemetry.istio.io/v1alpha1`) references providers defined in `meshConfig.extensionProviders`. Without modifying the Istio CR, this path is blocked.

3. **Kuadrant component tracing (partial)**: Authorino and Limitador CRs accept a `spec.tracing` section pointing to a collector endpoint. This generates independent spans for auth and rate-limit decisions. However:
   - Without a gateway-level parent span, these traces are NOT correlated with vLLM traces
   - Known limitation: trace IDs do not propagate to WASM modules in Istio/Envoy, breaking Limitador trace continuity ([docs](https://docs.kuadrant.io/1.3.x/kuadrant-operator/doc/observability/tracing/))
   - The Kuadrant operator manages Authorino/Limitador CRs — direct patches may be overwritten

4. **Full end-to-end tracing requires**: Either (a) an independent OSSM 3 instance with full `meshConfig` control, or (b) a GatewayClass that natively supports OTel tracing (e.g., Envoy Gateway). Both are significant scope changes.

### What to evaluate in RHOAI 3.4

- Changes to the GatewayClass or gateway data plane (Istio vs Envoy Gateway)
- Kuadrant CR consolidated tracing config (`spec.observability.tracing`) with end-to-end correlation
- WASM trace ID propagation fix
- OSSM 3 coexistence with cluster-ingress-operator
- Changes to LLMInferenceService affecting the serving path

### References

- [Kuadrant Tracing Docs v1.3.x](https://docs.kuadrant.io/1.3.x/kuadrant-operator/doc/observability/tracing/)
- [RHCL Observability Guide](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.1/html-single/connectivity_link_observability_guide/index)

---

## Task 3: Persistent Tempo Storage

**Context**: Current TempoMonolithic CR uses `backend: memory` -- traces are lost on pod restart. The values already have `storage.backend` and `storage.size` templated.

### Implementation

1. Add `pv` and `s3` backend options to `modules/observability/charts/tracing/values.yaml`:

```yaml
tempo:
  storage:
    backend: memory      # "memory" | "pv" | "s3"
    size: 10Gi
    # S3 config (only when backend: s3)
    s3:
      endpoint: ""
      bucket: tempo
      secretName: tempo-s3-credentials
```

1. Update `tempo-monolithic.yaml` template with conditional blocks:
  - `backend: memory` -- current behavior (no changes)
  - `backend: pv` -- add `volumeClaimTemplate` with the configured `size`
  - `backend: s3` -- add `s3` block with endpoint/bucket/secret reference (for ODF/MinIO)
2. Default remains `memory` so existing deployments are unaffected

### Validation

Deploy with `backend: pv`, restart Tempo pod, verify traces survive the restart.

---

## Task 4: Token-Level vLLM Tracing -- DONE

**Context**: Requires the OTel-enabled vLLM image from Task 1. With OTel packages present, vLLM can emit fine-grained spans for each token generation step. vLLM v0.7.3 supports `--otlp-traces-endpoint` CLI arg (env vars are silently ignored).

### Implementation

1. Update the vLLM command args in `modules/maas/charts/maas-model/templates/llm-inference-service.yaml`:
  - Add `--otlp-traces-endpoint` arg (in addition to the env vars) when `tracing.enabled` -- this enables vLLM's internal instrumentation for per-step spans
  - Add `--collect-detailed-traces` arg for token-level granularity (available in vLLM >= 0.6)
2. Add `tracing.detailed` flag in `maas-model/values.yaml` (default `false`):

```yaml
tracing:
  enabled: false
  detailed: false    # token-level spans (higher overhead)
  otlpEndpoint: "http://maas-collector-collector.observability.svc:4317"
```

1. This is opt-in on top of opt-in -- `tracing.enabled` must also be true

### Validation

Enable both flags, send inference request, verify Tempo shows child spans within the vLLM service (e.g., `generate`, `decode_step`).

---

## Task 5: Trace-Based SLO Alerts

**Context**: The OTel Collector's `spanmetrics` connector already exports `traces_spanmetrics_latency_bucket` and `traces_spanmetrics_calls_total` to Prometheus. The existing `prometheusrule-slo.yaml` alerts on vLLM-native metrics only.

### Implementation

1. Add a new template `modules/observability/charts/tracing/templates/prometheusrule-spanmetrics.yaml`:

```yaml
# Alerts:
- MaaSTraceP99LatencyHigh:
    expr: histogram_quantile(0.99, traces_spanmetrics_latency_bucket{...}) > threshold
- MaaSTraceErrorRateHigh:
    expr: rate(traces_spanmetrics_calls_total{status_code="ERROR"}) / rate(traces_spanmetrics_calls_total) > threshold
- MaaSTraceRequestRateAnomaly:
    expr: rate(traces_spanmetrics_calls_total) drop below threshold
```

1. Gate behind `alerting.enabled` in `modules/observability/charts/tracing/values.yaml`:

```yaml
alerting:
  enabled: false
  latencyP99Threshold: 30   # seconds
  errorRateThreshold: 0.05  # 5%
```

1. Add test assertion in `test_03_tracing.py` for the PrometheusRule existence

### Validation

Deploy with alerting enabled, verify PrometheusRule exists and alert expressions evaluate without errors in Thanos.

---

## Files Changed (Summary)

### Done

| Action   | File                                                                             | Description                                                 |
| -------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| New      | `modules/maas/images/vllm-cpu-otel/Containerfile`                                | vLLM CPU image with OTel packages                           |
| New      | `modules/observability/charts/grafana/dashboards/trace-search.json`              | Trace Search dashboard (table with service filter)          |
| New      | `modules/observability/charts/grafana/templates/grafana-dashboard-trace-search.yaml` | GrafanaDashboard CR for trace search                    |
| Modified | `modules/maas/charts/maas-model/values.yaml`                                     | Image tag + `tracing.detailed`                              |
| Modified | `modules/maas/charts/maas-model/templates/llm-inference-service.yaml`            | `--otlp-traces-endpoint` + `--collect-detailed-traces` args |
| Modified | `modules/observability/charts/grafana/templates/grafana-datasource.yaml`         | Deterministic `uid: prometheus`                             |
| Modified | `modules/observability/charts/grafana/templates/grafana-datasource-tempo.yaml`   | Deterministic `uid: tempo`                                  |
| Modified | `Makefile`                                                                       | `build-vllm-cpu-otel` + `push-vllm-cpu-otel` targets       |

### Pending

| Action   | File                                                                             | Description                                                 |
| -------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| New      | `modules/observability/charts/tracing/templates/prometheusrule-spanmetrics.yaml` | Spanmetrics SLO alerts                                      |
| Modified | `modules/observability/charts/tracing/values.yaml`                               | S3/PV storage config + alerting config                      |
| Modified | `modules/observability/charts/tracing/templates/tempo-monolithic.yaml`           | PV/S3 conditionals                                          |

### Deferred to RHOAI 3.4

| Action   | File                                                                             | Description                                                 |
| -------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| ~~New~~  | ~~`modules/maas/charts/maas-platform/templates/envoy-tracing.yaml`~~            | ~~Gateway Envoy OTLP tracing~~ (EnvoyExtensionPolicy not applicable to openshift-default) |


## References

- [ADR-0004: Tracing Stack](adr/0004-tracing-stack.md)
- [vLLM OTel PR #34466](https://github.com/vllm-project/vllm/pull/34466) -- OTel added to default requirements (Feb 2026)
- [vLLM OpenTelemetry docs](https://docs.vllm.ai/en/v0.9.0/examples/online_serving/opentelemetry.html)
- [rh-aiservices-bu/llm-on-openshift CPU Containerfile](https://github.com/rh-aiservices-bu/llm-on-openshift/blob/main/llm-servers/vllm/cpu/Containerfile)

