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
# Deploy infrastructure (EvalHub + MLflow)
# The model-auth Secret (service-serving CA) is created automatically by a post-install hook
make deploy-evaluation

# Run quality evaluation via EvalHub API (internal KServe URL)
make evalhub-eval EVALHUB_BENCHMARK=arc_easy \
    MODEL_URL=https://granite-2b-kserve-workload-svc.models-as-a-service.svc:8000/v1 \
    MODEL_NAME=granite-2b \
    TOKENIZER=ibm-granite/granite-3.1-2b-instruct \
    SECRET_REF=model-auth \
    EVAL_LIMIT=10

# Smoke test — validates full pipeline in <5 min (EvalHub → Job → MLflow)
make evalhub-smoke \
    MODEL_URL=https://granite-2b-kserve-workload-svc.models-as-a-service.svc:8000/v1

# Run performance benchmark via EvalHub API (default: throughput, 1 strategy)
make evalhub-benchmark \
    MODEL_URL=https://granite-2b-kserve-workload-svc.models-as-a-service.svc:8000/v1 \
    MODEL_NAME=granite-2b \
    SECRET_REF=model-auth

# Run security scan via Garak (reduced probe cap for speed)
make evalhub-security \
    MODEL_URL=https://granite-2b-kserve-workload-svc.models-as-a-service.svc:8000/v1 \
    MODEL_NAME=granite-2b

# List providers and benchmarks
make evalhub-providers

# List benchmark collections (e.g. leaderboard-v2)
make evalhub-collections

# List all evaluation jobs
make evalhub-jobs

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

The `model-auth` Secret with `ca_cert` is created automatically by a Helm post-install hook (`model-auth-init` Job) that reads the `openshift-service-ca.crt` ConfigMap. No manual setup required.

To add `api-key` or `hf-token` to the existing Secret:
```bash
oc patch secret model-auth -n evaluation --type merge \
    -p '{"stringData": {"api-key": "<token>"}}'
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

## Speed Recommendations

Evaluations on CPU models are slow. Use these settings for E2E validation (pipeline testing, not model evaluation):

| Provider | Fast E2E | Flag | Expected Time |
|----------|----------|------|--------------|
| lm-eval | `--limit 1` | `make evalhub-smoke` | ~15 min (CPU) |
| GuideLLM | `--benchmark throughput --max-seconds 30` | `make evalhub-benchmark` | ~8 min (CPU) |
| Garak | `--timeout 1200 --extra-params '{"garak_config":{"run":{"soft_probe_prompt_cap":1}}}'` | `make evalhub-security` | GPU only |
| Lighteval | Use small datasets (`glue:cola` ~250 items) | manual | ~10-20 min |

`make test-evalhub` runs smoke + benchmark sequentially (~25 min on CPU). Garak is excluded — it exceeds 1200s even with `soft_probe_prompt_cap=1` on CPU.

For production evaluations (GPU models), remove limits: `--benchmark sweep` for GuideLLM, higher `--limit` for lm-eval, full garak scan without `soft_probe_prompt_cap`.

**Why these defaults:**
- **GuideLLM throughput + max-seconds=30**: `throughput` is a single-strategy profile. Note: GuideLLM still runs a sweep internally (~9 benchmarks within the max-seconds window), but completes in ~8 min total on CPU vs hours with the `sweep` profile (10 strategies × unlimited time).
- **Garak GPU-only**: Even with `soft_probe_prompt_cap=1`, the Garak adapter times out at 1200s on CPU inference. The adapter-side timeout is not configurable below the scan duration. Run on GPU where it should complete in <5 min.
- **Lighteval**: Ignores `--limit` parameter. Use benchmarks with small datasets instead of hellaswag (~10k items, causes OOMKill).

## Known Limitations (RHOAI 3.4)

> **Component maturity:** MLflow (GA), LMEval (GA), TrustyAI (GA), EvalHub (**Tech Preview**).
> EvalHub limitations below are specific to the TP release and may change in future GA.

- **EVAL_LIMIT recommended for CPU models**: Evaluations generate sustained inference load. vLLM on CPU can OOMKill under heavy load (e.g. full arc_easy = 2376 calls). Use `EVAL_LIMIT=10` (default) for testing, increase for final evaluations on GPU.
- **Garak requires GPU**: Security scans (`garak` provider) exceed the adapter timeout (1200s) on CPU inference even with `soft_probe_prompt_cap=1`. Run `make evalhub-security` only against GPU-served models. Excluded from `make test-evalhub`.
- **GuideLLM does not log to MLflow**: The GuideLLM adapter reports metrics to EvalHub via events but does not create an MLflow run. Only lm-eval results appear in MLflow UI. Benchmark results are available via `make evalhub-status JOB_ID=<uuid>`.
- **Lighteval ignores `--limit`**: The lighteval adapter evaluates the full dataset regardless of the `limit` parameter.
- **MLflow Traces**: The MLflow server exposes the `/v1/traces` OTLP endpoint (documented since [RHOAI 3.3 architecture](https://github.com/opendatahub-io/architecture-context)) and can persist traces. However, the EvalHub adapter does not instrument LLM calls with `mlflow.trace()` yet — only final metrics are logged. Tracked upstream: [eval-hub#549](https://github.com/eval-hub/eval-hub/issues/549). The [EvalHub ADR](https://github.com/opendatahub-io/architecture-decision-records) (`ODH-ADR-EH-0001`) describes a dual tracing model where EvalHub creates the parent trace and benchmark pods emit spans via the AdapterFramework SDK, but this is not yet implemented.
- **External authenticated endpoints**: The `api-key` in `model.auth.secret_ref` is mounted at `/var/run/secrets/model/api-key` and exposed as `ModelCredentials.api_key` by the SDK (`auth.py`), but it is **not** set as `OPENAI_API_KEY` environment variable automatically. Each adapter decides how to use it. GuideLLM and lm-eval read `OPENAI_API_KEY` from the environment natively, so external authenticated endpoints may not work out-of-the-box. Use internal KServe URLs (no auth needed) for reliable evaluations; external gateway URLs only make sense for measuring real gateway latency.
- **Custom providers (BYOP)**: Custom providers with tenant scope don't resolve in job submissions (TP bug).

## Alternatives to the Bash Script

### EvalHub SDK CLI

The `eval-hub-sdk` (v0.4.0+) provides a Python CLI as an alternative to `scripts/evalhub.sh`:

```bash
pip install eval-hub-sdk
evalhub submit --provider lm_evaluation_harness --benchmark arc_easy --model-url <url>
evalhub list
evalhub status <job-id>
```

The SDK offers typed request/response objects, retry logic, and streaming logs. Use it when integrating evaluations into CI pipelines or notebooks.

### OCI Artifacts

EvalHub generates immutable OCI artifacts for each completed evaluation. These artifacts contain the full evaluation record (config, metrics, logs) and can be pushed to a container registry for auditing and reproducibility. This feature is available but not yet integrated into this project's workflow.

## Detailed Documentation

- [GuideLLM Benchmarks](BENCHMARKS.md) — scenarios, profiles, metrics
- [ADR-0008: EvalHub Orchestrator](../../../docs/adr/0008-evalhub-orchestrator.md) — decision rationale
