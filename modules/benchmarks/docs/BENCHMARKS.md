# Benchmarks Module

Load testing for LLM inference using [GuideLLM](https://github.com/vllm-project/guidellm) v0.6.0+.

## Prerequisites

- MaaS module deployed with at least one model running
- `oc` CLI logged into the cluster
- `helm` CLI available

## Quick Start

```bash
# 1. Deploy benchmarks infrastructure (namespace, PVC, ServiceAccount, CA bundle)
make deploy-benchmarks

# 2. Run a benchmark against the gateway (default scenario)
#    The command waits for the Job to complete and shows logs at the end
make run-benchmark BENCHMARK_TARGET=https://rh-ai.apps.<cluster-domain>/v1

# 3. Retrieve results from the PVC
POD=$(oc get pods -n benchmarks -l app.kubernetes.io/name=benchmarks --sort-by=.metadata.creationTimestamp -o name | tail -1)
oc cp -n benchmarks ${POD#pod/}:/results ./results
```

## Scenarios

| Scenario | Profile | Rates | Target | Purpose |
|----------|---------|-------|--------|---------|
| `gateway` (default) | concurrent | c=1,2,4,8 | Gateway route (external) | Measure real-world latency including auth + rate limiting |
| `baseline` | concurrent | c=1,2,4,8 | ClusterIP service (internal) | Measure raw inference latency without gateway overhead |
| `stress` | sweep | 5 auto-discovered points | Gateway route | Find max throughput and breaking point |
| `slo` | constant | 4 RPS | Gateway route | Validate PrometheusRules don't fire under target load |

Run a specific scenario:

```bash
# Gateway (default) -- needs BENCHMARK_TARGET for your cluster
make run-benchmark BENCHMARK_SCENARIO=gateway BENCHMARK_TARGET=https://rh-ai.apps.<cluster>/v1

# Baseline -- direct to model, no gateway (target hardcoded in values-baseline.yaml)
make run-benchmark BENCHMARK_SCENARIO=baseline

# Stress -- sweep auto-discovery
make run-benchmark BENCHMARK_SCENARIO=stress BENCHMARK_TARGET=https://rh-ai.apps.<cluster>/v1

# SLO -- constant 4 RPS
make run-benchmark BENCHMARK_SCENARIO=slo BENCHMARK_TARGET=https://rh-ai.apps.<cluster>/v1

# With authentication
make run-benchmark BENCHMARK_SCENARIO=gateway BENCHMARK_TARGET=https://... BENCHMARK_TOKEN=$(oc whoami -t)
```

### Scenario Details

**Gateway vs Baseline**: Running both with identical rates (c=1,2,4,8) allows direct A/B comparison of gateway overhead. The baseline target uses the kserve internal service (`https://<model>-kserve-workload-svc.<ns>.svc:8000/v1`).

**Stress (sweep)**: For the sweep profile, `--rate` means the **number of rate points to discover** (`sweep_size`), NOT the actual request rate. GuideLLM auto-discovers the rate range. `sweep_size` must be >= 2. The stress scenario needs more memory (4Gi limits) because sweep maintains state for all rate points concurrently.

**SLO (constant)**: Sends requests at a fixed rate (4 req/s). Useful for validating that PrometheusRules and SLO alerts don't fire under steady-state load.

## Processor (Tokenizer)

GuideLLM generates **synthetic data** for benchmark requests. To create prompts with an exact number of tokens, it needs the model's HuggingFace tokenizer. The `--processor` flag specifies the HuggingFace model ID (e.g., `TinyLlama/TinyLlama-1.1B-Chat-v1.0`). It downloads only the tokenizer (~KB), not the model weights.

This is needed because the OpenShift model name (e.g., `tinyllama-test`) doesn't match a HuggingFace model ID. Configure via `benchmark.processor` in `values.yaml`.

## TLS Verification

TLS verification uses the OpenShift cluster CA bundle, **not** `verify: false`:

1. A ConfigMap (`benchmarks-ca-bundle`) with annotation and label `config.openshift.io/inject-trusted-cabundle: "true"` is auto-populated by OpenShift with the cluster's trusted CA certificates
2. The Job mounts this CA bundle at `/etc/pki/tls/certs/ca-bundle.crt`
3. The `SSL_CERT_FILE` environment variable tells Python's `httpx` to use this file

This approach validates the OpenShift router's certificate properly. Both the annotation and label are required for OpenShift to inject the CA bundle.

## Payload Matrix

Configured via `benchmark.promptTokens` and `benchmark.outputTokens` in values:

| Scenario | Prompt Tokens | Output Tokens |
|----------|---------------|---------------|
| gateway / baseline / stress / slo | 32 | 64 |

Override inline:

```bash
make run-benchmark BENCHMARK_SCENARIO=gateway \
  BENCHMARK_TARGET=https://... \
  -- --set benchmark.promptTokens=256 --set benchmark.outputTokens=512
```

## Resource Requirements

| Scenario | CPU request/limit | Memory request/limit |
|----------|-------------------|----------------------|
| gateway / baseline / slo | 1 / 2 | 1Gi / 2Gi |
| stress (sweep) | 2 / 4 | 2Gi / 4Gi |

The sweep profile needs more memory because it maintains state for all auto-discovered rate points concurrently. With `sweep_size=10` and 2Gi limit, it OOMs.

## Key Metrics Collected

GuideLLM reports per-request:

- **TTFT** (Time To First Token) at P50/P90/P99
- **ITL** (Inter-Token Latency) at P50/P99
- **E2E latency** at P50/P90
- **Throughput** (total output tokens / wall clock seconds)

## Results

Results are stored in a PVC (`benchmarks-results`) at `/results/`:

- `benchmarks.json` -- full request-level data
- `benchmarks.csv` -- summary metrics

Copy results locally:

```bash
POD=$(oc get pods -n benchmarks -l app.kubernetes.io/name=benchmarks --sort-by=.metadata.creationTimestamp -o name | tail -1)
oc cp -n benchmarks ${POD#pod/}:/results ./results
```

## Authentication

For gateway endpoints that require auth:

```bash
# Using inline token (dev/test only)
make run-benchmark BENCHMARK_TARGET=https://... BENCHMARK_TOKEN=$(oc whoami -t)

# Using a Secret (recommended)
oc create secret generic benchmark-auth -n benchmarks --from-literal=token=$(oc whoami -t)
helm template benchmarks modules/benchmarks/charts/benchmarks \
  --set job.enabled=true \
  --set benchmark.authSecret=benchmark-auth \
  --show-only templates/job.yaml | oc create -f -
```

## GuideLLM Load Profiles

| Profile | `--rate` means | Behavior |
|---------|----------------|----------|
| `concurrent` | Parallel streams | Fixed number of parallel requests; replaces completed immediately |
| `constant` | Requests/second | Sends at a constant rate (RPS) |
| `poisson` | Avg requests/second | Requests drawn from Poisson distribution (realistic variance) |
| `sweep` | **Number of rate points** (sweep_size) | Auto-discovers rate range, tests N points. Must be >= 2 |
| `synchronous` | N/A | Single stream, one request at a time (baseline latency) |

## References

- [GuideLLM documentation](https://github.com/vllm-project/guidellm)
- [How to Deploy and Benchmark vLLM with GuideLLM on Kubernetes](https://developers.redhat.com/articles/2025/12/24/how-deploy-and-benchmark-vllm-guidellm-kubernetes)
- [MaaS-AI-Gateway-Performance-Scale methodology](https://github.com/arielharush96/MaaS-AI-Gateway-Performance-Scale)
