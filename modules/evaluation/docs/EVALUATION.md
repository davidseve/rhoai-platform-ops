# Evaluation Module

Unified LLM evaluation platform: quality assessment, experiment tracking, and performance benchmarks — all orchestrated through EvalHub (TrustyAI).

See [ADR-0007](../../../docs/adr/0007-merge-benchmarks-into-evaluation.md) for the benchmarks merge and [ADR-0008](../../../docs/adr/0008-evalhub-orchestrator.md) for the EvalHub orchestrator decision.

## Components

| Component | Purpose | Toggle |
|-----------|---------|--------|
| [EvalHub](https://eval-hub.github.io/) | Evaluation control plane — orchestrates all providers via REST API | `evalhub.enabled` |
| [MLflow](https://mlflow.org/) | Experiment tracking and artifact storage (auto-integrated with EvalHub) | `mlflow.enabled` |
| Providers | lm-evaluation-harness (167 benchmarks), GuideLLM (5 profiles), Garak (security), Lighteval (23 benchmarks) | Configured in EvalHub CR |

## Prerequisites

- RHOAI 3.4+ with TrustyAI and MLflow operators enabled in DSC
- Shared PostgreSQL database deployed (`make deploy-database`)
- `oc` CLI logged into the cluster
- `helm` and `curl` available

## Quick Start

```bash
# Deploy infrastructure (EvalHub + MLflow + benchmarks infra)
make deploy-evaluation

# Run quality evaluation via EvalHub API
make evalhub-eval EVALHUB_BENCHMARK=arc_easy \
    MODEL_URL=https://rh-ai.apps.<cluster>/v1 \
    MODEL_NAME=TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
    EVAL_LIMIT=10

# Run performance benchmark via EvalHub API
make evalhub-benchmark EVALHUB_BENCHMARK=sweep \
    MODEL_URL=https://rh-ai.apps.<cluster>/v1 \
    MODEL_NAME=tinyllama-test

# List providers and benchmarks
make evalhub-providers

# Check job status
make evalhub-status JOB_ID=<uuid>

# Run tests
make test-evaluation
```

## EvalHub API

EvalHub exposes a REST API for submitting evaluations. All commands go through `scripts/evalhub.sh`.

### Authentication

- **Bearer token**: `oc whoami -t` (OpenShift user token)
- **X-Tenant header**: namespace where jobs run (default: `evaluation`)

### Providers

| Provider | Type | Benchmarks | Use Case |
|----------|------|-----------|----------|
| `lm_evaluation_harness` | Quality | 167+ (arc_easy, mmlu, hellaswag, leaderboard_*, ...) | Model quality assessment |
| `guidellm` | Performance | sweep, throughput, concurrent, constant, poisson | Load testing, latency analysis |
| `garak` | Security | owasp_llm_top10, avid, prompt_injection, ... | Red-teaming, vulnerability scanning |
| `lighteval` | Quality | 23 (hellaswag, winogrande, gsm8k, mmlu, ...) | Lightweight alternative to lm-eval |

### Collections

- **leaderboard-v2**: 6 benchmarks (IFEval, BBH, GPQA, MMLU-Pro, MuSR, MATH-Hard) with pass criteria thresholds

### Model URL

Use the external gateway URL for model access (avoids TLS certificate issues with internal services):

```
https://rh-ai.apps.<cluster>/v1
```

See [ADR-0008](../../../docs/adr/0008-evalhub-orchestrator.md) for the TLS limitation details.

### Results

EvalHub automatically logs results to MLflow. Access the MLflow UI:

```bash
oc get route mlflow -n redhat-ods-applications -o jsonpath='{.spec.host}'
```

## Detailed Documentation

- [GuideLLM Benchmarks](BENCHMARKS.md) — scenarios, profiles, metrics
- [ADR-0008: EvalHub Orchestrator](../../../docs/adr/0008-evalhub-orchestrator.md) — decision rationale
