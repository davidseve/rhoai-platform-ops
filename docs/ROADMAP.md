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

### Phase 1: Observability

Goal: understand what usage patterns exist before setting limits.

- [ ] Enable OpenShift User Workload Monitoring (if not already active)
- [ ] Deploy Grafana Operator + instance
- [ ] Configure Prometheus datasource (Thanos Querier)
- [ ] Create dashboards:
  - Platform overview (gateway requests, latency, error rates)
  - vLLM model metrics (tokens/sec, queue depth, GPU/CPU utilization)
  - Per-tier usage (requests and tokens by tier)
- [ ] Configure PodMonitor for vLLM pods
- [ ] Set up alerting rules (PrometheusRule) for SLO violations
- [ ] E2E tests: Grafana up, datasources connected, metrics visible

**Red Hat products**: Cluster Observability Operator, OpenShift User Workload Monitoring, Grafana Operator.

**Reference**: [RHOAI 3.3 Managing Observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/managing_openshift_ai/managing-observability_managing-rhoai)

### Phase 2: Traceability

Goal: trace individual requests through the full stack (client -> gateway -> model).

- [ ] Deploy Red Hat build of OpenTelemetry Collector
- [ ] Deploy Red Hat build of Tempo for trace storage
- [ ] Configure TelemetryPolicy on Kuadrant gateway
- [ ] Configure vLLM OpenTelemetry integration (OTEL_EXPORTER_OTLP_ENDPOINT)
- [ ] Add Tempo datasource to Grafana
- [ ] Create trace exploration dashboard
- [ ] E2E tests: traces visible for inference requests

**Red Hat products**: Red Hat build of OpenTelemetry, Red Hat build of Tempo.

### Phase 3: Benchmarks

Goal: identify system limits with repeatable load tests.

- [ ] Set up benchmark runner (Python script or inference-perf)
- [ ] Define scenarios:
  - Code assistant: long prompts, code completion patterns
  - Cluster operations (MCP): short prompts, JSON tool call responses
  - Stress test: ramp to max throughput
- [ ] Integrate with MLflow for result tracking
- [ ] Create comparison reports (current vs baseline)
- [ ] E2E tests: benchmark suite runs and logs results

**Tools**: kubernetes-sigs/inference-perf, MLflow.

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
