# GuideLLM Performance Benchmarks

Load testing for LLM inference using [GuideLLM](https://github.com/vllm-project/guidellm) via the EvalHub API.

Part of the evaluation module (see [ADR-0008](adr/0008-evalhub-orchestrator.md)).

## Prerequisites

- Evaluation module deployed (`make deploy-evaluation`)
- At least one model running (e.g., `granite-2b`)
- `oc` CLI logged into the cluster

## Quick Start

```bash
# Run a performance benchmark (throughput profile, 30s max)
make evalhub-benchmark MODEL_NAME=granite-2b

# Run a full sweep (multiple rate points, production profiling)
./scripts/evalhub.sh submit --provider guidellm --benchmark sweep \
    --model-url https://granite-2b-kserve-workload-svc.models-as-a-service.svc:8000/v1 \
    --model-name granite-2b --secret-ref model-auth --wait

# Check job status
make evalhub-status JOB_ID=<uuid>
```

## Available Profiles

| Profile | `--benchmark` value | Behavior |
|---------|---------------------|----------|
| `throughput` | `throughput` | Single concurrent strategy, measures max tokens/sec |
| `sweep` | `sweep` | Auto-discovers rate range, tests multiple points |
| `concurrent` | `concurrent` | Fixed number of parallel streams |
| `constant` | `constant` | Sends at a constant rate (RPS) |
| `poisson` | `poisson` | Requests drawn from Poisson distribution |

## Key Metrics

GuideLLM reports per-request:

- **TTFT** (Time To First Token) at P50/P90/P99
- **ITL** (Inter-Token Latency) at P50/P99
- **E2E latency** at P50/P90
- **Throughput** (total output tokens / wall clock seconds)

## Results

Results are stored in the EvalHub database and queryable via:

```bash
# Check job results
make evalhub-status JOB_ID=<uuid>

# List all completed jobs
make evalhub-jobs
```

## Authentication

EvalHub handles TLS trust via the `model-auth` Secret (created automatically by a post-install hook with the OpenShift service-serving CA). Pass `--secret-ref model-auth` for internal KServe endpoints.

## References

- [GuideLLM documentation](https://github.com/vllm-project/guidellm)
- [How to Deploy and Benchmark vLLM with GuideLLM on Kubernetes](https://developers.redhat.com/articles/2025/12/24/how-deploy-and-benchmark-vllm-guidellm-kubernetes)
- [MaaS-AI-Gateway-Performance-Scale methodology](https://github.com/arielharush96/MaaS-AI-Gateway-Performance-Scale)
