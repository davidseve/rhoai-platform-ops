# Roadmap

Master plan for the RHOAI Platform Operations project. Each pillar is implemented as an independent module.

## Pillar Overview

| Pillar | Module | Purpose | Dependencies |
|--------|--------|---------|-------------|
| **MaaS** | `modules/maas/` | Model serving with API governance | None (base module) |
| **Observability** | `modules/observability/` | Metrics, dashboards, alerts | MaaS (for vLLM metrics) |
| **Traceability** | Part of observability | Request tracing with OpenTelemetry + Tempo | Observability module |
| **Benchmarks** | `modules/benchmarks/` | Load testing and performance baselines | MaaS (models must be running) |
| **Evaluation** | `modules/evaluation/` | MLflow tracking, experiment comparison | None (independent) |

## Implementation Order

### Phase 0: Foundation (DONE)

- [x] MaaS module: RHOAI + Kuadrant + LLMInferenceService
- [x] Tiered access: free/premium with request and token rate limits
- [x] ArgoCD app-of-apps with module toggles
- [x] E2E tests: inference, in-cluster access, governance
- [x] Project scaffold: .cursor rules, skills, ADRs

### Phase 1: Observability (DONE)

Goal: understand what usage patterns exist before setting limits.

- [x] Enable OpenShift User Workload Monitoring (declarative ConfigMap)
- [x] Deploy Grafana Operator + instance (with OpenShift OAuth proxy)
- [x] Configure Prometheus datasource (Thanos Querier via SA token)
- [x] Create dashboards:
  - Platform overview (gateway requests, rejection ratio, per-model/user)
  - vLLM model metrics (tokens/sec, latency percentiles, KV cache, scheduler)
  - Per-tier usage (requests and tokens by tier)
- [x] Configure PodMonitor for vLLM pods (TLS via service-ca CA bundle)
- [x] Set up alerting rules (PrometheusRule) for SLO violations (latency, KV cache, errors)
- [x] E2E tests: Grafana up, datasources connected, metrics visible, dashboards exist
- [x] ADR-0003: Grafana Operator choice (community) with COO Perses migration path

**Red Hat products**: OpenShift User Workload Monitoring, Grafana Operator (community, see [ADR-0003](adr/0003-grafana-operator.md)).

**Reference**: [RHOAI 3.3 Managing Observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/managing_openshift_ai/managing-observability_managing-rhoai)

### Phase 2: Traceability (DONE)

Goal: trace individual requests through the full stack (client -> gateway -> model).

- [x] Deploy Red Hat build of OpenTelemetry Collector (OTel Operator + Collector CR)
- [x] Deploy Red Hat build of Tempo for trace storage (Tempo Operator + TempoMonolithic CR)
- [x] Configure vLLM OpenTelemetry integration (OTEL env vars, opt-in via `tracing.enabled`)
- [x] Add Tempo datasource to Grafana (GrafanaDatasource CR with service map + node graph)
- [x] Create trace exploration dashboard (service map, latency, recent traces, request rate)
- [x] OTel Collector spanmetrics connector (derives RED metrics from traces)
- [x] ServiceMonitor for OTel Collector metrics
- [x] E2E tests: operator CSVs, Tempo/Collector pods, datasource, trace visibility
- [x] ADR-0004: Tracing stack choice (Red Hat OTel + Tempo)
- [ ] Configure TelemetryPolicy on Kuadrant gateway (deferred to Phase 2b)

**Red Hat products**: Red Hat build of OpenTelemetry, Red Hat build of Tempo.

**Reference**: [OBSERVABILITY.md](../modules/observability/docs/OBSERVABILITY.md#distributed-tracing)

### Phase 2b: Traceability Enhancements

Stretch goals deferred from Phase 2. See [ADR-0004](adr/0004-tracing-stack.md) for context.

- [ ] Gateway/Envoy distributed tracing (Istio `Telemetry` CR for Envoy -> OTel Collector)
- [ ] Persistent Tempo storage (switch from memory to PV/S3 backend)
- [ ] Token-level vLLM tracing (fine-grained per-token spans, requires newer vLLM image)
- [ ] Trace-based SLO alerts (PrometheusRule from spanmetrics-derived data)

### Phase 3: Benchmarks

Goal: identify system limits with repeatable load tests.

- [ ] Set up benchmark runner based on Mooncake trace replay approach
  - Adapt [llm-d-tuning-mooncake](https://github.com/cemigo114/llm-d-tuning-mooncake) `mooncake_replay.py` for RHOAI endpoints
  - Support OpenAI-compatible request format with controlled prefix sharing
  - Parameterize: concurrency, max tokens, request count, trace source
- [ ] Define scenarios:
  - Code assistant: long prompts, code completion patterns (maps to Mooncake "conversation" trace -- high prefix sharing)
  - Cluster operations (MCP): short prompts, JSON tool call responses (maps to Mooncake "toolagent" trace -- diverse prefixes)
  - Stress test: ramp to max throughput
- [ ] Collect key metrics per request (from llm-d-tuning-mooncake methodology):
  - TTFT (Time To First Token) at P50/P90/P99
  - ITL (Inter-Token Latency) at P50/P99
  - E2E latency at P50/P90
  - Throughput (total output tokens / wall clock seconds)
  - TPSU (Tokens Per Second per User)
- [ ] Build results analysis tooling
  - Adapt `analyze_results.py` to generate comparison tables (current vs baseline)
  - Per-request JSON output for reproducibility and independent verification
- [ ] Integrate with MLflow for result tracking
- [ ] E2E tests: benchmark suite runs and logs results

**Tools**: kubernetes-sigs/inference-perf, MLflow, [llm-d-tuning-mooncake](https://github.com/cemigo114/llm-d-tuning-mooncake) (reference for trace replay and analysis scripts).

**Reference insights from llm-d-tuning-mooncake**:
- Conversation workloads (high prefix sharing) benefit most from prefix-cache-aware routing
- Toolagent workloads (diverse prefixes) need load-balanced routing with higher defer thresholds
- KV cache pressure becomes critical at ~6-8K input tokens -- benchmark both short (4K) and long (8K+) sequences
- Queue depth, KV cache utilization, and cache hit rate are the metrics that correlate most with serving quality

### Phase 4: Evaluation

Goal: track experiments and compare model/configuration changes.

- [ ] Deploy MLflow Tracking Server on OpenShift
- [ ] Configure persistent storage (S3/MinIO or PVC)
- [ ] Integrate benchmark results logging
- [ ] Create experiment comparison workflows
- [ ] E2E tests: MLflow up, can log and retrieve experiments

**Tools**: MLflow (community; evaluate RHOAI MLflow Operator when available).

## Decision Log

Key decisions are documented as ADRs in [docs/adr/](adr/):

- [ADR-0001: Module structure and Helm-first workflow](adr/0001-module-structure.md)
- [ADR-0002: Red Hat product priority](adr/0002-red-hat-priority.md)
- [ADR-0003: Grafana Operator for dashboards](adr/0003-grafana-operator.md)
- [ADR-0004: Tracing stack (OTel + Tempo)](adr/0004-tracing-stack.md)
