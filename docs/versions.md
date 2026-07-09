# Component Versions

Versions used in this project, aligned with RHOAI 3.4 GA.

**Note:** RHOAI is set to latest 3.4.x (`installPlanApproval: Automatic`, currently 3.4.2 in catalog) to validate regression fixes (Perses TLS, Prometheus secret, Gateway OOM). COO is enabled (`coo.enabled: true`). RHCL is pinned to 1.3.4 (`startingCSV: rhcl-operator.v1.3.4`) because RHCL 1.4.0 adds `allow_on_headers_stop_iteration` to the Wasm plugin config, which Envoy 1.34.x (Service Mesh 3.3.x) does not recognize, causing the Authorization header to not be forwarded to Authorino. See [ADR-0014](adr/0014-wasm-plugin-get-auth-failure.md).

## RHOAI Core

| Component | Version | Channel | Reference |
|---|---|---|---|
| RHOAI Operator | 3.4.2 (latest) | `stable-3.4` | [Supported Configs](https://access.redhat.com/articles/rhoai-supported-configs-3.x) |
| KServe | 0.17.0 | -- | Managed by RHOAI operator |
| MaaS (Models-as-a-Service) | 0.1.1 (GA) | -- | Managed by RHOAI operator |
| llm-d (distributed inference) | 0.7.1 (GA) | -- | Used via LLMInferenceService (single-replica CPU, no disaggregation) |
| Red Hat AI Inference Server | 3.4.0 (GA) | -- | Not used (custom vLLM CPU) |

## API Governance

| Component | Version | Channel | Reference |
|---|---|---|---|
| RHCL Operator (Kuadrant) | 1.3.4 (pinned) | `stable` | [RHCL Docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.1) |
| LeaderWorkerSet | 1.0 | `stable-v1.0` | Required for llm-d |

## Observability

| Component | Version | Channel | Reference |
|---|---|---|---|
| Cluster Observability Operator (COO) | 1.x | `stable` | [COO Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/) ([ADR-0013](adr/0013-coo-observability-migration.md)) |
| Grafana Operator | 5.x | `v5` | Community operator ([ADR-0003](adr/0003-grafana-operator.md)) |
| Red Hat build of OpenTelemetry | -- | `stable` | [OTel Docs](https://docs.redhat.com/en/documentation/red_hat_build_of_opentelemetry/) |
| Red Hat build of Tempo | -- | `stable` | [Tempo Docs](https://docs.redhat.com/en/documentation/red_hat_build_of_opentelemetry/) |

## Model Serving

| Component | Version | Notes |
|---|---|---|
| vLLM CPU (custom) | 0.3-otel | `quay.io/dseveria/vllm-cpu-openai-ubi9:0.3-otel` -- Red Hat has no x86_64 CPU image |
| vLLM CUDA (RHOAI) | v0.18.0 | `quay.io/modh/vllm:rhoai-2.25-cuda` (for GPU deployments) |
| TinyLlama 1.1B | 1.0 | `oci://quay.io/rh-aiservices-bu/tinyllama:1.0` |

## Evaluation

| Component | Version | Status | Reference |
|---|---|---|---|
| EvalHub | ~0.4.0 | **Tech Preview** | Managed by TrustyAI operator ([ADR-0008](adr/0008-evalhub-orchestrator.md)) |
| MLflow | 3.10.1 | **GA** | Managed by RHOAI operator (`mlflow.opendatahub.io/v1`) |
| LMEval (lm-evaluation-harness) | 0.4.8 | **GA** | Managed by TrustyAI operator (`trustyai.opendatahub.io/v1alpha1`) |
| TrustyAI Operator | 1.37.0 | **GA** | DSC component (`trustyai: Managed`) |

## Model Registry

| Component | Version | Status | Reference |
|---|---|---|---|
| Model Registry Operator | 0.3.x | **GA** | Managed by RHOAI operator (`modelregistry: Managed`) |
| Kubeflow Model Registry | 1.11+ | -- | [Upstream](https://github.com/opendatahub-io/model-registry-operator) |

## Platform

| Component | Version | Notes |
|---|---|---|
| OpenShift Container Platform | 4.19.9+ / 4.20 / 4.21 | [Supported Configs](https://access.redhat.com/articles/rhoai-supported-configs-3.x) |
| OpenShift Service Mesh 3 | 3.3.4 | Managed by RHOAI operator; Envoy 1.34.2-dev ([ADR-0014](adr/0014-wasm-plugin-get-auth-failure.md) — GET auth bug) |
| PostgreSQL | 16 | `registry.redhat.io/rhel9/postgresql-16` (shared DB for maas-api and EvalHub) |

## Version Bump Summary (3.3 -> 3.4 GA)

| Component | 3.3 | 3.4 GA |
|---|---|---|
| KServe | 0.15 | **0.17.0** |
| vLLM CUDA/ROCm | v0.13.0 | **v0.18.0** |
| MaaS | 0.0.2 (TP) | **0.1.1 (GA)** |
| MLflow | 3.6.0 (TP) | **3.10.1 (GA)** |
| LMEval | -- | **0.4.8 (GA)** |
| TrustyAI | -- | **1.37.0 (GA)** |
| EvalHub | -- | **~0.4.0 (TP)** |
| Data Science Pipelines | 2.5.0 | **2.16.0** |
| llm-d | -- | **0.7.1 (GA)** |
| AI Inference Server | -- | **3.4.0 (GA)** |
