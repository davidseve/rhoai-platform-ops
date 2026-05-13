# Benchmarks Module

Load testing for LLM inference using [GuideLLM](https://github.com/vllm-project/guidellm) v0.6.0+.

## Prerequisites

- MaaS module deployed with at least one model running
- `oc` CLI logged into the cluster
- `helm` CLI available

## Quick Start

```bash
# 1. Deploy benchmarks infrastructure (namespace, PVC, ServiceAccount)
make deploy-benchmarks

# 2. Run a benchmark against the gateway (default scenario)
make run-benchmark BENCHMARK_TARGET=https://maas.apps.<cluster-domain>/v1

# 3. Check job status
oc get jobs -n benchmarks -w

# 4. Retrieve results
oc cp benchmarks/<pod-name>:/results ./benchmark-results
```

## Scenarios

| Scenario | Profile | Target | Purpose |
|----------|---------|--------|---------|
| `gateway` (default) | concurrent 1→8 | Gateway route (external) | Measure real-world latency including auth + rate limiting |
| `baseline` | concurrent 1→32 | ClusterIP service (internal) | Measure raw inference latency without gateway overhead |
| `stress` | sweep | Gateway route | Find max throughput and breaking point |
| `slo` | constant 10 RPS | Gateway route | Validate PrometheusRules don't fire under target load |

Run a specific scenario:

```bash
make run-benchmark BENCHMARK_SCENARIO=baseline
make run-benchmark BENCHMARK_SCENARIO=stress BENCHMARK_TARGET=https://maas.apps.<cluster>/v1
make run-benchmark BENCHMARK_SCENARIO=slo BENCHMARK_TARGET=https://maas.apps.<cluster>/v1
```

## Payload Matrix

Configured via `benchmark.promptTokens` and `benchmark.outputTokens` in values:

| Size | Prompt Tokens | Output Tokens |
|------|---------------|---------------|
| Small | 32 | 64 |
| Medium (default) | 256 | 512 |
| Large | 1024 | 1024 |

Override inline:

```bash
helm template benchmarks modules/benchmarks/charts/benchmarks \
  --set job.enabled=true \
  --set benchmark.promptTokens=32 \
  --set benchmark.outputTokens=64 \
  | oc apply -f -
```

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
# Find the pod name
POD=$(oc get pods -n benchmarks -l app.kubernetes.io/name=benchmarks --sort-by=.metadata.creationTimestamp -o name | tail -1)
oc cp -n benchmarks ${POD#pod/}:/results ./results
```

## Authentication

For gateway endpoints that require auth:

```bash
# Using inline token (dev/test only)
helm template benchmarks modules/benchmarks/charts/benchmarks \
  --set job.enabled=true \
  --set benchmark.authToken=$(oc whoami -t) \
  | oc apply -f -

# Using a Secret (recommended)
oc create secret generic benchmark-auth -n benchmarks --from-literal=token=$(oc whoami -t)
helm template benchmarks modules/benchmarks/charts/benchmarks \
  --set job.enabled=true \
  --set benchmark.authSecret=benchmark-auth \
  | oc apply -f -
```

## GuideLLM Load Profiles

| Profile | Behavior |
|---------|----------|
| `concurrent` | Fixed number of parallel streams; replaces completed requests immediately |
| `constant` | Sends requests at a constant rate (req/sec) |
| `poisson` | Requests drawn from Poisson distribution (realistic variance) |
| `sweep` | Tests multiple configurations in one run to find operating range |
| `synchronous` | Single stream, one request at a time (baseline latency) |

## References

- [GuideLLM documentation](https://github.com/vllm-project/guidellm)
- [How to Deploy and Benchmark vLLM with GuideLLM on Kubernetes](https://developers.redhat.com/articles/2025/12/24/how-deploy-and-benchmark-vllm-guidellm-kubernetes)
- [MaaS-AI-Gateway-Performance-Scale methodology](https://github.com/arielharush96/MaaS-AI-Gateway-Performance-Scale)
