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

# Create model-auth Secret (required for internal TLS to KServe services)
oc create secret generic model-auth -n evaluation \
    --from-literal=ca_cert="$(oc get cm openshift-service-ca.crt -n evaluation \
        -o jsonpath='{.data.service-ca\.crt}')"

# Run quality evaluation via EvalHub API (internal KServe URL)
make evalhub-eval EVALHUB_BENCHMARK=arc_easy \
    MODEL_URL=https://tinyllama-fast-kserve-workload-svc.models-as-a-service.svc:8000/v1 \
    MODEL_NAME=tinyllama-fast \
    TOKENIZER=TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
    SECRET_REF=model-auth \
    EVAL_LIMIT=10

# Run performance benchmark via EvalHub API
make evalhub-benchmark EVALHUB_BENCHMARK=sweep \
    MODEL_URL=https://tinyllama-fast-kserve-workload-svc.models-as-a-service.svc:8000/v1 \
    MODEL_NAME=tinyllama-fast \
    SECRET_REF=model-auth

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

### Model URL and Authentication

EvalHub-created pods need TLS trust and authentication to access model endpoints. Use `model.auth.secret_ref` to reference a K8s Secret with credentials:

**Secret format** (mount path: `/var/run/secrets/model/`):

| Key | Purpose | Required |
|-----|---------|----------|
| `ca_cert` | CA certificate for internal TLS (service-serving CA) | Yes for internal URLs |
| `api-key` | API key, set as `OPENAI_API_KEY` in the pod | Only for authenticated endpoints |
| `hf-token` | HuggingFace token for gated models/datasets | Only for gated resources |

**Recommended setup** — internal KServe URL with service-CA:

```bash
# Create Secret with OpenShift service-serving CA
oc create secret generic model-auth -n evaluation \
    --from-literal=ca_cert="$(oc get cm openshift-service-ca.crt -n evaluation \
        -o jsonpath='{.data.service-ca\.crt}')"
```

The internal URL bypasses gateway authentication (no `api-key` needed):
```
https://<model>-kserve-workload-svc.models-as-a-service.svc:8000/v1
```

**Important**: `model.name` must match the vLLM `--served-model-name`. Use `--tokenizer` to specify the HuggingFace model ID for tokenizer download.

### Results

Results are stored in EvalHub's database and queryable via the API:

```bash
# Check job results
make evalhub-status JOB_ID=<uuid>

# Or via script
./scripts/evalhub.sh status <job-id>
```

**MLflow integration:** EvalHub logs metrics and parameters to MLflow automatically when the `experiment` field is included in the job submission. The `evalhub.sh` script adds this field by default (auto-generated from the job name, or pass `--experiment <name>`).

Each completed evaluation creates an MLflow run with:
- **Metrics**: benchmark-specific (e.g. `acc`, `acc_norm`, `overall_score`)
- **Params**: `benchmark_id`, `model_name`, `num_examples_evaluated`, `duration_seconds`

MLflow UI: `oc get route mlflow -n redhat-ods-applications -o jsonpath='{.spec.host}'`

**MLflow API** (requires `X-Mlflow-Workspace` header):
```bash
MLFLOW_ROUTE=$(oc get route mlflow -n redhat-ods-applications -o jsonpath='{.spec.host}')
TOKEN=$(oc whoami -t)

# List experiments
curl -sk "https://${MLFLOW_ROUTE}/api/2.0/mlflow/experiments/search" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Mlflow-Workspace: evaluation" \
    -H "Content-Type: application/json" \
    -d '{"max_results": 100}'

# Search runs for an experiment
curl -sk "https://${MLFLOW_ROUTE}/api/2.0/mlflow/runs/search" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Mlflow-Workspace: evaluation" \
    -H "Content-Type: application/json" \
    -d '{"experiment_ids": ["<id>"], "max_results": 10}'
```

**Note:** MLflow uses `--workspace-store-uri=kubernetes://`, so each K8s namespace maps to an MLflow workspace. The `evaluation` workspace corresponds to the `evaluation` namespace where EvalHub runs jobs.

## Detailed Documentation

- [GuideLLM Benchmarks](BENCHMARKS.md) — scenarios, profiles, metrics
- [ADR-0008: EvalHub Orchestrator](../../../docs/adr/0008-evalhub-orchestrator.md) — decision rationale
