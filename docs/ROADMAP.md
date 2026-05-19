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

#### Completed

- [x] **vLLM CPU image con OpenTelemetry** -- imagen custom `quay.io/dseveria/vllm-cpu-openai-ubi9:0.3-otel` con `opentelemetry-sdk`, `opentelemetry-exporter-otlp`, etc. ([Containerfile](../modules/maas/images/vllm-cpu-otel/Containerfile))
- [x] **vLLM tracing funcional** -- `--otlp-traces-endpoint` CLI arg (vLLM v0.7.3 ignora env vars OTEL), spans visibles en Tempo
- [x] **Token-level tracing** -- `--collect-detailed-traces request` opt-in via `tracing.detailed: true`
- [x] **Dashboards de tracing** -- Trace Exploration (service map, latency, request rate) + Trace Search (tabla con filtro por servicio y Trace ID clickable)
- [x] **Datasource UIDs determinísticos** -- `uid: prometheus` y `uid: tempo` para evitar roturas por UIDs aleatorios del operador Grafana

#### Pending

- Persistent Tempo storage (switch from memory to PV/S3 backend)
- Trace-based SLO alerts (PrometheusRule from spanmetrics)
- **Kuadrant WASM CEL errors (resolved in GA)**: EA2 had ~333 errors/hour caused by `groups_str` bug in maas-controller TRLP predicates (PR #543). Fixed in RHOAI 3.4 GA — MaaSAuthPolicy uses API key subscription scoping instead of `groups_str`. Verify `kuadrant_errors` drops to ~0 after GA deployment.
- **TelemetryPolicy CEL incompatibility (non-fatal in GA)**: `responseBodyJSON("/model")` and `auth.identity.selected_subscription` are Kuadrant WASM expressions, NOT valid Authorino CEL. Tenant CR with `telemetry.enabled: true` auto-creates a TelemetryPolicy with these expressions. Authorino logs `failed to parse CEL expression` errors — **non-fatal** (metric label evaluation only, not auth decisions). **GA finding (2026-05-18)**: Unlike EA2 where this caused 403 errors (conflated with TLS issue), in GA these CEL errors are strictly cosmetic. The 403 was caused by Authorino→maas-api TLS trust, not CEL. Tenant `telemetry.enabled: true` is safe to use. **Impact**: Limitador metrics lack `model`, `subscription`, `organization_id`, and `cost_center` labels — only aggregate gateway-level metrics. Per-model attribution requires Kuadrant to separate WASM and Authorino CEL expression evaluation. **Current approach**: Tenant `telemetry.enabled: true` enabled via Helm template (ArgoCD SSA). **Re-evaluate in RHOAI 3.5+** for per-model metric labels.
- **MaaSAuthPolicy 403 on API key inference (RESOLVED 2026-05-18)**: Root cause was Authorino→maas-api TLS trust. Fix: mount `openshift-service-ca.crt` ConfigMap + `SSL_CERT_FILE` env var. Automated as ArgoCD PostSync Job (`authorino-tls-job.yaml`). See commit `552276c`.
- **Gateway→Authorino listener TLS (RESOLVED 2026-05-19)**: Initially marked as "not feasible" due to 500 errors when enabling `listener.tls.enabled: true` on the Authorino CR. Root cause was RBAC issues in the PostSync Job, not the TLS setup itself. The `security.opendatahub.io/authorino-tls-bootstrap: "true"` Gateway annotation correctly triggers the Kuadrant controller to create the `*-authn-ssl` EnvoyFilter with TLS transport. **Fix**: restored full 8-step TLS setup in PostSync Job (`authorino-tls-job.yaml`) with complete RBAC (services, secrets, configmaps, deployments, authorinos in kuadrant-system + gateways, envoyfilters in openshift-ingress). Steps: (1) annotate Authorino service for serving cert, (2) wait for cert secret, (3) enable listener TLS on Authorino CR, (4-6) outbound CA trust (service-ca ConfigMap + volume + SSL_CERT_FILE), (7) wait for readiness, (8) trigger Gateway EnvoyFilter reconciliation.
- **AuthPolicy per-model behavior**: MaaSAuthPolicy creates AuthPolicies that accept OCP tokens ONLY for `/v1/models` (listing). Inference (`/v1/chat/completions`) requires API keys (`sk-oai-*`). This is by design in RHOAI 3.4 GA. Tests using OCP tokens for inference must be refactored to use API keys.
- **ArgoCD PreDelete hooks for ordered cleanup**: ArgoCD sync-waves control creation order but NOT deletion order between child apps in app-of-apps (all children delete simultaneously). This causes stuck `models-as-a-service` namespace because operators (wave 0) are deleted before their CRs (wave 2) resolve finalizers. ArgoCD 3.3+ adds `argocd.argoproj.io/hook: PreDelete` — add a PreDelete Job to `maas-operators` that clears LLMInferenceService/DSC/DSCI finalizers before operators are removed. **Blocked on**: OpenShift GitOps shipping ArgoCD 3.3+ (current: GitOps 1.20.3 = ArgoCD 2.x). **Workaround**: `scripts/cluster-cleanup.sh` deletes apps in reverse wave order manually. See [ArgoCD 3.3 PreDelete](https://dev.to/x4nent/argocd-33-predelete-hook-making-gitops-deletion-a-safe-lifecycle-3f28).
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
> **Status (2026-05-14)**: RHOAI 3.4 GA available. Operator channel updated to `stable-3.4`. MaaSAuthPolicy enabled. See [ADR-0005](adr/0005-maas-subscription-model.md).
>
> **Evaluated:**
> - [x] maas-controller AuthPolicy management -- `opendatahub.io/managed: "false"` works in 3.4. `cleanup-authn-hook` disabled.
> - [x] Authorino TLS bootstrap -- `security.opendatahub.io/authorino-tls-bootstrap: "true"` handles TLS automatically. `kuadrant-readiness-hook` disabled.
> - [x] MaaSSubscription model -- adopted. Models moved to `models-as-a-service` namespace. Per-tier RLP/TRLP disabled, subscriptions manage rate limits.
> - [x] PostgreSQL for maas-api -- evaluation DB in `modules/maas/prereqs/maas-db.yaml`, automated in Makefile.
> - [x] New CRDs: Tenant (auto-created), MaaSModelRef, MaaSSubscription, gateway-default-auth/deny (auto-created by controller).
> - [x] New DSC components: `rawDeploymentServiceConfig: Headed`, `sparkoperator: Removed`, `kserve.wva: Removed`.
>
> **EA2 known bug (fixed in GA):** Token rate limits didn't fire in EA2 -- `maas-controller` TRLP predicates used `auth.identity.groups_str` but AuthPolicy's KubernetesTokenReview put groups in `auth.identity.user.groups`. Fixed in GA via [PR #543](https://github.com/opendatahub-io/models-as-a-service/pull/543). MaaSAuthPolicy enabled, xfail markers removed.
>
> **GA validation (2026-05-14) — key findings:**
> - MaaSSubscription `owner.groups` must use **Kubernetes groups** (from TokenReview), NOT OpenShift Group objects. TokenReview returns `cluster-admins`, `system:authenticated:oauth`, `system:authenticated` — but NOT `maas-test-users` or `tier-premium-users`. Fixed in commit `3d9e5ca`.
> - TelemetryPolicy disabled (`telemetry.enabled: false`) — `responseBodyJSON()` is a Kuadrant WASM function, not valid Authorino CEL. Causes 403 on all requests when MaaSAuthPolicy is active. Fixed in commit `205d39f`.
> - MaaSAuthPolicy 403 on API key inference — **RESOLVED (2026-05-18)**. Root cause: Authorino could not reach maas-api's `/internal/v1/api-keys/validate` endpoint because it did not trust the OpenShift service-ca certificate. Fix: mount `openshift-service-ca.crt` ConfigMap into Authorino deployment and set `SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca.crt`. Upstream documents this in `scripts/setup-authorino-tls.sh`. Must be automated in Helm charts.
> - AuthPolicy per-model design: OCP tokens accepted for `/v1/models` listing only; inference (`/v1/chat/completions`) requires API keys (`sk-oai-*`). Multiple subscriptions require `X-MaaS-Subscription` header. This is by design — inference tests need `maas_api_key` fixture, not `maas_token`.
>
> **Evaluated (2026-05-11):**
> - [x] GatewayClass tracing nativo — **NOT AVAILABLE**. `data-science-gateway-class` uses `openshift.io/gateway-controller/v1` (Istio managed by cluster-ingress-operator). The managed Istio CR cannot be customized with `extensionProviders` for OTel. Would require independent OSSM 3 or upstream controller changes.
> - [x] RHCL operator: mover a `openshift-operators` — **IMPLEMENTED** on branch `feat/rhcl-openshift-operators`. Subscription moved from `kuadrant-system` to `openshift-operators` (global OperatorGroup). OperatorGroup removed. Kuadrant CR stays in `kuadrant-system`.
> - [x] WASM trace ID propagation (Limitador) — **NOT AVAILABLE**. Kuadrant 1.3.x: W3C `traceparent` headers NOT propagated to WASM modules. Known upstream limitation, no fix available. See [Kuadrant Tracing Docs](https://docs.kuadrant.io/1.3.x/kuadrant-operator/doc/observability/tracing/).
>
> **Evaluated (2026-05-18, clean cluster OCP 4.20.8 + RHOAI 3.4 GA):**
> - [x] Tenant CR — auto-created as `default-tenant` in `models-as-a-service` namespace with `spec.telemetry.enabled: true`. Controller creates TelemetryPolicy + Istio Telemetry automatically.
> - [x] TelemetryPolicy CEL — **STILL BROKEN in GA**. Tenant creates `maas-telemetry` TelemetryPolicy with WASM expressions (`responseBodyJSON("/model")`, `auth.identity.selected_subscription`). Authorino logs `failed to parse CEL expression` errors but these are **non-fatal** (metric label errors only, not auth denials). The CEL errors do NOT cause 403 — the 403 was from TLS. Patch Tenant to `telemetry.enabled: false` to suppress errors; controller does NOT auto-delete the TelemetryPolicy.
> - [x] MaaSAuthPolicy 403 on API key inference — **RESOLVED**. Root cause was Authorino→maas-api TLS trust. See GA validation findings above.
> - [x] Kuadrant/Authorino namespace — confirmed **`kuadrant-system`** on RHOAI 3.4 GA (not `rh-connectivity-link`). Upstream docs are misleading for RHOAI installations.
> - [x] maas-controller auto-resources — controller creates: `gateway-default-auth` AuthPolicy (Enforced: False, overridden by per-model policies), `gateway-default-deny` TokenRateLimitPolicy, TelemetryPolicy, DestinationRule, NetworkPolicy. Per-model: `maas-auth-<model>` AuthPolicy (Enforced: True), `maas-trlp-<model>` TRLP. No conflicts with Helm resources when `opendatahub.io/managed: "false"` is set.
> - [x] Authorino TLS setup — requires manual steps from upstream `scripts/setup-authorino-tls.sh`: (1) annotate service for cert, (2) mount `openshift-service-ca.crt` ConfigMap, (3) set `SSL_CERT_FILE` env var. The `authorino-tls-bootstrap` Gateway annotation creates EnvoyFilter for Gateway→Authorino TLS but does NOT handle Authorino→maas-api outbound trust.
> - [x] HTTPRoute paths — RHOAI 3.4 GA uses namespaced paths: `/models-as-a-service/<model>/v1/chat/completions`. Tests must use full path.
> - [x] DSCI auto-creation — operator creates `default-dsci` automatically. Helm should NOT manage it (`dsci.managed: false`).
> - [x] `models-as-a-service` namespace — created by maas-controller. Helm must use `namespace.create: false`.
>
> **Evaluated (2026-05-18, continued):**
> - [x] OSSM 3 meshConfig — **NOT APPLICABLE**. RHOAI 3.4 GA uses `openshift.io/gateway-controller/v1` (cluster-ingress-operator managed Istio). OSSM 3 is NOT required and would conflict. The managed Istio cannot be customized with `extensionProviders`. Gateway tracing remains blocked until Kuadrant supports tracing natively or the controller allows custom Istio config.
> - [x] Authorino ServiceMonitor — **NOT INVESTIGATED** (low priority). maas-api runs in `redhat-ods-applications` and likely exposes a metrics port, but scraping it requires a ServiceMonitor in that namespace. Deferred to Phase 3+ when FinOps dashboards need maas-api metrics (API key usage, subscription counts).
> - [x] Dashboard flags `modelAsService` + `observabilityDashboard` — **VALIDATED**. `genAiStudio: true` and `modelAsService: true` are required in OdhDashboardConfig for the MaaS/GenAI Studio UI. Both work in GA. `observabilityDashboard: true` requires Cluster Observability Operator (COO), which is NOT deployed — left as `false`. See `values.yaml` dashboard section.
> - [x] Unified endpoint routing — **NOT AVAILABLE in 3.4 GA**. LLMInferenceService creates per-model HTTPRoutes with namespaced paths (`/<namespace>/<model>/v1/...`). No routing-by-payload (model field in JSON body) support. Each model requires its own path prefix. Single-endpoint routing would require a custom HTTPRoute or middleware — not worth the complexity for current use cases.
>
> **RHOAI 3.4 GA documentation analysis (2026-05-18):**
>
> Analysis of [RHOAI 3.4 official docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4) and [upstream MaaS setup](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/maas-setup.md). Key findings:
>
> **Version bumps (3.3 → 3.4 GA):** KServe 0.15→0.17.0, vLLM v0.13.0→v0.18.0 (CUDA), MaaS 0.0.2(TP)→0.1.1(GA), MLflow 3.6.0(TP)→3.10.1(GA), llm-d 0.7.1(GA, new), Red Hat AI Inference Server 3.4.0(GA, new).
>
> **New: Tenant CR** — `maas.opendatahub.io/v1alpha1 Tenant` auto-created by maas-controller. `spec.telemetry.enabled: true` makes the controller manage TelemetryPolicy + Istio Telemetry. Could fix CEL blocker. Name must be `default-tenant` (CEL enforced).
>
> **New: maas-controller auto-resources** — controller creates `gateway-default-auth` AuthPolicy, `gateway-default-deny` TokenRateLimitPolicy, TelemetryPolicy, DestinationRule, NetworkPolicy. Need conflict audit with Helm templates.
>
> **GatewayClassName:** Upstream docs use `openshift-default`, we use `data-science-gateway-class` (created by RHOAI when KServe Managed). Keeping current value — validate on cluster.
>
> **Gateway listener config:** Upstream defines HTTP(80)+HTTPS(443) with hostname and `from: All`. We have HTTPS-only, no hostname, `from: Selector`. More restrictive = better security. Validate HTTPRoutes are accepted.
>
> **vLLM CPU x86_64:** Red Hat does NOT publish an x86_64 CPU image (`odh-vllm-cpu-rhel9` only has ppc64le/s390x). Custom image `quay.io/dseveria/vllm-cpu-openai-ubi9:0.3-otel` remains necessary. Base community image (`quay.io/rh-aiservices-bu/vllm-cpu-openai-ubi9`) has no newer versions than 0.3.
>
> **Kuadrant namespace:** Upstream mentions `AUTHORINO_NAMESPACE=rh-connectivity-link` for RHOAI. Hardcoded `kuadrant-system` in templates replaced with `{{ .Values.kuadrant.namespace }}` for flexibility.
>
> **Deprecations:** TGIS, ModelMesh, Serverless KServe, Kubeflow v1 Training Operator — none used in this project.
>
> **Installation flow:** Database → Gateway → DSC → Models. Current sync-waves: 0(operators+DB) → 1(platform+gateway+DSC) → 2(models). Close enough — ArgoCD retries handle ordering within a wave.
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
- [ ] Find model limits with payload sweep
  - Run stress (sweep) with growing payloads: small (32/64), medium (256/512), large (1024/1024)
  - Build throughput vs payload size curve to identify where the model degrades
- [ ] Build Prometheus monitoring during benchmarks
  - Adapt approach from [MaaS-AI-Gateway-Performance-Scale](https://github.com/arielharush96/MaaS-AI-Gateway-Performance-Scale): collect pod CPU/memory/network + Istio/Authorino latency during each test run
  - Correlate infrastructure metrics with GuideLLM results
  - Monitor `kserve_vllm:gpu_cache_usage_perc` during tests (GPU deployments)
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