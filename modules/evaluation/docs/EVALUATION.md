# Evaluation Module

Unified LLM evaluation platform: quality assessment (EvalHub), experiment tracking (MLflow), and performance benchmarks (GuideLLM).

See [ADR-0007](../../../docs/adr/0007-merge-benchmarks-into-evaluation.md) for the decision to merge benchmarks into this module.

## Components

| Component | Purpose | Toggle |
|-----------|---------|--------|
| [EvalHub](https://eval-hub.github.io/) | Evaluation control plane (TrustyAI, RHOAI 3.4 TP) | `evalhub.enabled` |
| [MLflow](https://mlflow.org/) | Experiment tracking and artifact storage | `mlflow.enabled` |
| [GuideLLM](https://github.com/vllm-project/guidellm) | Load testing and performance benchmarks | `benchmarks.enabled` |
| LMEvalJob | On-demand model quality evaluations (lm-evaluation-harness) | `lmeval.enabled` |

## Prerequisites

- RHOAI 3.4+ with TrustyAI and MLflow operators enabled in DSC
- Shared PostgreSQL database deployed (`make deploy-database`)
- `oc` CLI logged into the cluster
- `helm` CLI available

## Quick Start

```bash
# Deploy everything (EvalHub + MLflow + benchmarks infra)
make deploy-evaluation

# Run a quality evaluation
make run-evaluation EVAL_TASK=arc_easy EVAL_LIMIT=10

# Run a performance benchmark
make run-benchmark BENCHMARK_SCENARIO=gateway BENCHMARK_TARGET=https://rh-ai.apps.<cluster>/v1

# Run tests
make test-evaluation
```

## Detailed Documentation

- [GuideLLM Benchmarks](BENCHMARKS.md) -- scenarios, profiles, metrics, results
