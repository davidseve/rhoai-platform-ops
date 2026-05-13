# Roadmap

Master plan for the RHOAI Platform Operations project. Each pillar is implemented as an independent module.

## Pillar Overview


| Pillar            | Module                   | Purpose                                    | Dependencies                  |
| ----------------- | ------------------------ | ------------------------------------------ | ----------------------------- |
| **MaaS**          | `modules/maas/`          | Model serving with API governance          | None (base module)            |
| **Observability** | `modules/observability/` | Metrics, dashboards, alerts                | MaaS (for vLLM metrics)       |
| **Traceability**  | Part of observability    | Request tracing with OpenTelemetry + Tempo | Observability module          |
| **Benchmarks**    | `modules/benchmarks/`    | Load testing and performance baselines     | MaaS (models must be running) |
| **Evaluation**    | `modules/evaluation/`    | MLflow tracking, experiment comparison     | None (independent)            |


## Implementation Order

### Phase 0: Foundation (DONE)

- MaaS module: RHOAI + Kuadrant + LLMInferenceService
- Tiered access: free/premium with request and token rate limits
- ArgoCD app-of-apps with module toggles
- E2E tests: inference, in-cluster access, governance
- Project scaffold: .claude rules, skills, ADRs

### Phase 1: Observability (DONE)

Goal: understand what usage patterns exist before setting limits.

- Enable OpenShift User Workload Monitoring (declarative ConfigMap)
- Deploy Grafana Operator + instance (with OpenShift OAuth proxy)
- Configure Prometheus datasource (Thanos Querier via SA token)
- Create dashboards:
  - Platform overview (gateway requests, rejection ratio, per-model/user)
  - vLLM model metrics (tokens/sec, latency percentiles, KV cache, scheduler)
  - Per-tier usage (requests and tokens by tier)
- Configure PodMonitor for vLLM pods (TLS via service-ca CA bundle)
- Set up alerting rules (PrometheusRule) for SLO violations (latency, KV cache, errors)
- E2E tests: Grafana up, datasources connected, metrics visible, dashboards exist
- ADR-0003: Grafana Operator choice (community) with COO Perses migration path

**Red Hat products**: OpenShift User Workload Monitoring, Grafana Operator (community, see [ADR-0003](adr/0003-grafana-operator.md)).

**Reference**: [RHOAI 3.3 Managing Observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/managing_openshift_ai/managing-observability_managing-rhoai)

### Phase 2: Traceability (DONE)

Goal: trace individual requests through the full stack (client -> gateway -> model).

- Deploy Red Hat build of OpenTelemetry Collector (OTel Operator + Collector CR)
- Deploy Red Hat build of Tempo for trace storage (Tempo Operator + TempoMonolithic CR)
- Configure vLLM OpenTelemetry integration (OTEL env vars, opt-in via `tracing.enabled`)
- Add Tempo datasource to Grafana (GrafanaDatasource CR with service map + node graph)
- Create trace exploration dashboard (service map, latency, recent traces, request rate)
- OTel Collector spanmetrics connector (derives RED metrics from traces)
- ServiceMonitor for OTel Collector metrics
- E2E tests: operator CSVs, Tempo/Collector pods, datasource, trace visibility
- ADR-0004: Tracing stack choice (Red Hat OTel + Tempo)
- Configure TelemetryPolicy on Kuadrant gateway (deferred to Phase 2b)

**Red Hat products**: Red Hat build of OpenTelemetry, Red Hat build of Tempo.

**Reference**: [OBSERVABILITY.md](../modules/observability/docs/OBSERVABILITY.md#distributed-tracing)

### Phase 2b: Traceability Enhancements (IN PROGRESS)

Stretch goals deferred from Phase 2. See [ADR-0004](adr/0004-tracing-stack.md) for context and [PHASE-2B-PLAN.md](PHASE-2B-PLAN.md) for the detailed implementation plan.

#### Completado

- [x] **vLLM CPU image con OpenTelemetry** -- imagen custom `quay.io/dseveria/vllm-cpu-openai-ubi9:0.3-otel` con `opentelemetry-sdk`, `opentelemetry-exporter-otlp`, etc. ([Containerfile](../modules/maas/images/vllm-cpu-otel/Containerfile))
- [x] **vLLM tracing funcional** -- `--otlp-traces-endpoint` CLI arg (vLLM v0.7.3 ignora env vars OTEL), spans visibles en Tempo
- [x] **Token-level tracing** -- `--collect-detailed-traces request` opt-in via `tracing.detailed: true`
- [x] **Dashboards de tracing** -- Trace Exploration (service map, latency, request rate) + Trace Search (tabla con filtro por servicio y Trace ID clickable)
- [x] **Datasource UIDs determinísticos** -- `uid: prometheus` y `uid: tempo` para evitar roturas por UIDs aleatorios del operador Grafana

#### Pendiente

- Persistent Tempo storage (switch from memory to PV/S3 backend)
- Trace-based SLO alerts (PrometheusRule from spanmetrics)
- **Kuadrant WASM auth timeout (blocker for high concurrency)**: timeout hardcoded a 200ms, causa 500 errors con >=4 requests paralelos. **Nota (2026-05-12)**: el ratio actual de errores es ~0.09/s (~333/hour) pero NO son timeouts. Son errores de evaluación CEL causados por el bug `groups_str`: cada request evalúa ~6 descriptores TRLP que referencia `auth.identity.groups_str` (Null), generando `CelError::Resolve { UnexpectedType { got: "Null", want: "Arc<String>" } }`. Las requests NO fallan (200/201), los errores son internos al pipeline de rate limiting. Se resolverán con GA + PR #543 (fix de `groups_str`)
- **Gateway production hardening**: tune Authorino limits/HPA, connection pooling, client retry guidance
- **Cluster Observability Operator (COO)**: instalar cuando el observability stack de RHOAI pase a GA (estimado 3.5+). COO habilita dashboards nativos en la consola OpenShift (PersesDashboard), UIPlugins de tracing/troubleshooting, y detección de incidentes (Korrel8r). Prerequisito para `observabilityDashboard: true` en OdhDashboardConfig. No conflicta con Grafana/OTel/Tempo actuales. Ya preparado en `values.yaml` con `observabilityDashboard: false`.

#### Diferido a RHOAI 3.4 -- Gateway distributed tracing

> **Decisión (2026-04-30)**: El tracing end-to-end gateway → auth → ratelimit → vLLM se difiere hasta evaluar RHOAI 3.4 y los cambios en el stack MaaS/Gateway.
>
> **Por qué**: El enfoque original (`EnvoyExtensionPolicy` de `extensions.kuadrant.io`) era incorrecto — esa API pertenece a Envoy Gateway, no al stack Istio/OSSM que usa `openshift-default` GatewayClass. El Istio CR del cluster-ingress-operator es gestionado y no se puede customizar con `extensionProviders` para OTel. Las alternativas viables (OSSM 3 independiente, o tracing de componentes Kuadrant sin correlación) tienen un coste/beneficio cuestionable hasta que el stack evolucione.
>
> **Qué evaluar en RHOAI 3.4**:
> - Si el GatewayClass cambia o soporta tracing nativo
> - Si el Kuadrant CR consolida configuración de tracing con correlación end-to-end
> - Si la propagación de trace IDs a WASM modules (Limitador) se resuelve ([limitación conocida](https://docs.kuadrant.io/1.3.x/kuadrant-operator/doc/observability/tracing/))
> - Si OSSM 3 permite meshConfig custom sin conflicto con el cluster-ingress-operator
> - Cambios en LLMInferenceService que afecten al serving path
> - **Mover RHCL operator a `openshift-operators`**: actualmente la Subscription y el OperatorGroup están en `kuadrant-system`. El patrón correcto para operadores cluster-wide es instalar la Subscription en `openshift-operators` (aprovechando el OperatorGroup global) y mantener solo el CR Kuadrant en `kuadrant-system`. Cambios necesarios: mover Subscription, eliminar OperatorGroup propio, actualizar `values.yaml`.
>
> **Referencias**: [Kuadrant Tracing Docs](https://docs.kuadrant.io/1.3.x/kuadrant-operator/doc/observability/tracing/), [RHCL Observability](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.1/html-single/connectivity_link_observability_guide/index)
>
> **Status (2026-05-07)**: RHOAI 3.4 EA2 evaluated on branch `feat/enhanced-dashboards`. See [ADR-0005](adr/0005-maas-subscription-model.md).
>
> **Evaluated:**
> - [x] maas-controller AuthPolicy management -- `opendatahub.io/managed: "false"` works in 3.4. `cleanup-authn-hook` disabled.
> - [x] Authorino TLS bootstrap -- `security.opendatahub.io/authorino-tls-bootstrap: "true"` handles TLS automatically. `kuadrant-readiness-hook` disabled.
> - [x] MaaSSubscription model -- adopted. Models moved to `models-as-a-service` namespace. Per-tier RLP/TRLP disabled, subscriptions manage rate limits.
> - [x] PostgreSQL for maas-api -- evaluation DB in `modules/maas/prereqs/maas-db.yaml`, automated in Makefile.
> - [x] New CRDs: Tenant (auto-created), MaaSModelRef, MaaSSubscription, gateway-default-auth/deny (auto-created by controller).
> - [x] New DSC components: `rawDeploymentServiceConfig: Headed`, `sparkoperator: Removed`, `kserve.wva: Removed`.
>
> **EA2 known bug:** Token rate limits don't fire -- `maas-controller` TRLP predicates use `auth.identity.groups_str` but AuthPolicy's KubernetesTokenReview puts groups in `auth.identity.user.groups`. Fixed upstream in [PR #543](https://github.com/opendatahub-io/models-as-a-service/pull/543), expected in GA.
>
> **Evaluated (2026-05-11):**
> - [x] GatewayClass tracing nativo — **NOT AVAILABLE**. `data-science-gateway-class` uses `openshift.io/gateway-controller/v1` (Istio managed by cluster-ingress-operator). The managed Istio CR cannot be customized with `extensionProviders` for OTel. Would require independent OSSM 3 or upstream controller changes.
> - [x] RHCL operator: mover a `openshift-operators` — **IMPLEMENTED** on branch `feat/rhcl-openshift-operators`. Subscription moved from `kuadrant-system` to `openshift-operators` (global OperatorGroup). OperatorGroup removed. Kuadrant CR stays in `kuadrant-system`.
> - [x] WASM trace ID propagation (Limitador) — **NOT AVAILABLE**. Kuadrant 1.3.x: W3C `traceparent` headers NOT propagated to WASM modules. Known upstream limitation, no fix available. See [Kuadrant Tracing Docs](https://docs.kuadrant.io/1.3.x/kuadrant-operator/doc/observability/tracing/).
>
> **Not evaluated yet:**
> - [ ] OSSM 3 meshConfig custom sin conflicto con cluster-ingress-operator
### Phase 3: Benchmarks

Goal: identify system limits with repeatable load tests.

- [x] Set up benchmark runner with [GuideLLM](https://github.com/neuralmagic/guidellm) (v0.6.0+)
  - OpenAI-compatible load generator with native TTFT, ITL, throughput collection
  - Profiles: `concurrent` (fixed parallelism), `sweep` (auto-find operating range), `poisson` (realistic arrivals), `constant` (fixed RPS)
  - Output: JSON + CSV reports with per-request timings
  - Deploy as Kubernetes Job with results to PVC
  - TLS via cluster CA bundle injection (not `verify: false`)
  - `--processor` for HuggingFace tokenizer (synthetic data generation)
- [x] Define scenarios:
  - `gateway`: concurrent c=1,2,4,8 against external Gateway route
  - `baseline`: concurrent c=1,2,4,8 direct to kserve workload service (A/B vs gateway)
  - `stress`: sweep auto-discovery (5 rate points, 4Gi memory)
  - `slo`: constant 4 RPS, validate SLO alerts don't fire
- [x] Payload matrix: all scenarios use small payload (32/64 tokens) for CPU model; configurable via values overrides
- [x] Collect key metrics per request:
  - TTFT (Time To First Token) at P50/P90/P99
  - ITL (Inter-Token Latency) at P50/P99
  - E2E latency at P50/P90
  - Throughput (total output tokens / wall clock seconds)
- [ ] Build Prometheus monitoring during benchmarks
  - Adapt approach from [MaaS-AI-Gateway-Performance-Scale](https://github.com/arielharush96/MaaS-AI-Gateway-Performance-Scale): collect pod CPU/memory/network + Istio/Authorino latency during each test run
  - Correlate infrastructure metrics with GuideLLM results
- [ ] Integrate with MLflow for result tracking
- [x] E2E tests: 16 tests (13 template validation + 3 cluster infra)
- [x] `make run-benchmark` waits for Job completion and shows logs

**Tools**: [GuideLLM](https://github.com/neuralmagic/guidellm) (load generation + metrics), MLflow (result tracking).

**Reference**: [MaaS-AI-Gateway-Performance-Scale](https://github.com/arielharush96/MaaS-AI-Gateway-Performance-Scale) -- methodology for A/B baseline vs gateway testing, Prometheus monitoring during benchmarks, and concurrency sweep patterns. Uses `llm-d-inference-sim` for deterministic backend; our benchmarks use real TinyLlama models to measure actual inference performance.

**Why GuideLLM over Mooncake trace replay (2026-05-13)**: GuideLLM (vLLM project, v0.6.0) is significantly more mature -- collects TTFT/ITL/throughput natively, supports sweep profiles to auto-discover operating ranges, outputs JSON/CSV/HTML, and installs with `pip`. Mooncake trace replay scripts required substantial adaptation and lacked automated sweep. Trade-off: GuideLLM doesn't support controlled prefix sharing (relevant for KV cache benchmarks); revisit if prefix-cache-aware routing becomes a priority.

### Phase 4: Evaluation

Goal: track experiments and compare model/configuration changes.

- Deploy MLflow Tracking Server on OpenShift
- Configure persistent storage (S3/MinIO or PVC)
- Integrate benchmark results logging
- Create experiment comparison workflows
- E2E tests: MLflow up, can log and retrieve experiments

**Tools**: MLflow (community; evaluate RHOAI MLflow Operator when available).

## Decision Log

Key decisions are documented as ADRs in [docs/adr/](adr/):

- [ADR-0001: Module structure and Helm-first workflow](adr/0001-module-structure.md)
- [ADR-0002: Red Hat product priority](adr/0002-red-hat-priority.md)
- [ADR-0003: Grafana Operator for dashboards](adr/0003-grafana-operator.md)
- [ADR-0004: Tracing stack (OTel + Tempo)](adr/0004-tracing-stack.md)
- [ADR-0005: MaaS Subscription Model (RHOAI 3.4)](adr/0005-maas-subscription-model.md)