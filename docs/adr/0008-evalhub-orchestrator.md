# ADR-0008: EvalHub as Evaluation Orchestrator

## Status

Accepted

## Context

The evaluation module has two parallel paths for running evaluations and benchmarks:

1. **Direct templates**: Helm-rendered LMEvalJob (lm-evaluation-harness) and GuideLLM Job (performance benchmarks) applied via `oc create`. Results require manual collection.
2. **EvalHub API**: REST API control plane (TrustyAI, RHOAI 3.4 Tech Preview) that creates K8s Jobs internally, manages lifecycle, and logs results to MLflow automatically.

Maintaining both paths adds operational overhead and defeats the purpose of having a control plane. EvalHub is the Red Hat standard for LLM evaluation, supports 4 providers (lm-evaluation-harness, guidellm, garak, lighteval) with 167+ benchmarks, and integrates with MLflow out of the box.

## Options Considered

### Option 1: Keep both paths equally

- Pros: Maximum flexibility, no dependency on Tech Preview
- Cons: Two ways to do the same thing, confusing for operators, duplicate maintenance

### Option 2: EvalHub as primary, direct templates as deprecated fallback

- Pros: Consolidates on Red Hat standard, automatic MLflow integration, single API for all providers
- Cons: Dependency on Tech Preview (may have bugs), TLS limitation for internal model URLs

### Option 3: Remove direct templates entirely

- Pros: Simplest, no ambiguity
- Cons: No fallback if EvalHub is unavailable or broken, too aggressive for Tech Preview

## Decision

**Option 2**: EvalHub API is the primary interface for all evaluations and benchmarks. Direct LMEvalJob and GuideLLM Job templates are deprecated but kept as fallback.

New Makefile targets (`evalhub-eval`, `evalhub-benchmark`, etc.) use `scripts/evalhub.sh` to call the EvalHub REST API. Legacy targets (`run-evaluation`, `run-benchmark`) print a deprecation warning.

## Consequences

### Positive

- Single interface for all evaluation types (quality, performance, security)
- Automatic MLflow experiment tracking — no manual result collection
- Red Hat supported path forward (EvalHub GA expected in RHOAI 3.5+)
- Collection support (e.g. `leaderboard-v2`) for standardized evaluation suites

### Negative

- **TLS resolved via `model.auth.secret_ref`**: EvalHub-created pods don't set `REQUESTS_CA_BUNDLE` by default, but `model.auth.secret_ref` mounts a K8s Secret at `/var/run/secrets/model/`. A `ca_cert` key in the Secret is used as `verify_certificate` by the adapter. Create a Secret with the OpenShift service-serving CA to use internal KServe URLs.
- **`model.name` vs tokenizer**: `model.name` must match the vLLM `--served-model-name`. Use `parameters.tokenizer` to specify the HuggingFace model ID for tokenizer download.
- **MLflow logging requires `experiment` field**: The `experiment.name` field must be included in the job submission payload for the adapter to log metrics to MLflow. Without it, MLflow experiments are created but runs are not logged. The `evalhub.sh` script adds this field automatically.
- **MLflow Tracing not yet instrumented**: The MLflow server supports trace ingestion (`/v1/traces` OTLP endpoint, available since RHOAI 3.3), but the EvalHub adapter does not emit traces — only final metrics. Tracked: [eval-hub#549](https://github.com/eval-hub/eval-hub/issues/549). The EvalHub ADR (`ODH-ADR-EH-0001`) plans dual tracing (parent trace from EvalHub, child spans from benchmark pods via AdapterFramework SDK).
- Tech Preview means potential instability or breaking changes
- Custom providers (BYOP) with tenant scope don't resolve in job submissions (TP bug, tracked)

### API Reference

```bash
# Auth: Bearer token (oc whoami -t) + X-Tenant header
POST /api/v1/evaluations/jobs          # Submit evaluation
GET  /api/v1/evaluations/jobs          # List jobs
GET  /api/v1/evaluations/jobs/{id}     # Job status + results
GET  /api/v1/evaluations/providers     # List providers and benchmarks
GET  /api/v1/evaluations/collections   # List collections
```

Key fields in the job submission body:
- `model.name`: must match vLLM `--served-model-name` (not the HuggingFace model ID)
- `model.auth.secret_ref`: K8s Secret name with keys `api-key`, `ca_cert`, `hf-token`
- `benchmarks[].parameters.tokenizer`: HuggingFace model ID for tokenizer download

### When to Remove Deprecated Templates

Remove `lmevaljob.yaml`, `benchmarks-job.yaml`, and supporting templates when:
1. EvalHub reaches GA (expected RHOAI 3.5+)
2. TLS limitation is resolved (custom env/volume support per job)
3. All evaluation workflows are validated through EvalHub API
