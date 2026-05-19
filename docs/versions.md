# Component Versions

Versions used in this project, aligned with RHOAI 3.4 GA.

## RHOAI Core

| Component | Version | Channel | Reference |
|---|---|---|---|
| RHOAI Operator | 3.4 GA | `stable-3.4` | [Supported Configs](https://access.redhat.com/articles/rhoai-supported-configs-3.x) |
| KServe | 0.17.0 | -- | Managed by RHOAI operator |
| MaaS (Models-as-a-Service) | 0.1.1 (GA) | -- | Managed by RHOAI operator |
| llm-d (distributed inference) | 0.7.1 (GA) | -- | Not used (CPU deployment) |
| Red Hat AI Inference Server | 3.4.0 (GA) | -- | Not used (custom vLLM CPU) |

## API Governance

| Component | Version | Channel | Reference |
|---|---|---|---|
| RHCL Operator (Kuadrant) | 1.3+ | `stable` | [RHCL Docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.1) |
| LeaderWorkerSet | 1.0 | `stable-v1.0` | Required for llm-d |

## Observability

| Component | Version | Channel | Reference |
|---|---|---|---|
| Grafana Operator | 5.x | `v5` | Community operator ([ADR-0003](adr/0003-grafana-operator.md)) |
| Red Hat build of OpenTelemetry | -- | `stable` | [OTel Docs](https://docs.redhat.com/en/documentation/red_hat_build_of_opentelemetry/) |
| Red Hat build of Tempo | -- | `stable` | [Tempo Docs](https://docs.redhat.com/en/documentation/red_hat_build_of_opentelemetry/) |

## Model Serving

| Component | Version | Notes |
|---|---|---|
| vLLM CPU (custom) | 0.3-otel | `quay.io/dseveria/vllm-cpu-openai-ubi9:0.3-otel` -- Red Hat has no x86_64 CPU image |
| vLLM CUDA (RHOAI) | v0.18.0 | `quay.io/modh/vllm:rhoai-2.25-cuda` (for GPU deployments) |
| TinyLlama 1.1B | 1.0 | `oci://quay.io/rh-aiservices-bu/tinyllama:1.0` |

## Platform

| Component | Version | Notes |
|---|---|---|
| OpenShift Container Platform | 4.19.9+ / 4.20 / 4.21 | [Supported Configs](https://access.redhat.com/articles/rhoai-supported-configs-3.x) |
| PostgreSQL | 16 | `registry.redhat.io/rhel9/postgresql-16` (maas-api DB) |

## Version Bump Summary (3.3 -> 3.4 GA)

| Component | 3.3 | 3.4 GA |
|---|---|---|
| KServe | 0.15 | **0.17.0** |
| vLLM CUDA/ROCm | v0.13.0 | **v0.18.0** |
| MaaS | 0.0.2 (TP) | **0.1.1 (GA)** |
| MLflow | 3.6.0 (TP) | **3.10.1 (GA)** |
| Data Science Pipelines | 2.5.0 | **2.16.0** |
| llm-d | -- | **0.7.1 (GA)** |
| AI Inference Server | -- | **3.4.0 (GA)** |
