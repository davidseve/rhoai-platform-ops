# ADR-0007: Merge Benchmarks into Evaluation Module

## Status

Accepted

## Context

The repository maintains two separate modules for LLM evaluation:

- **benchmarks** (`modules/benchmarks/`): GuideLLM-based load testing for performance profiling (latency, throughput, TTFT, ITL).
- **evaluation** (`modules/evaluation/`): EvalHub + MLflow for quality evaluation (accuracy, safety) and experiment tracking.

Both are LLM evaluation tools targeting different dimensions (performance vs quality). Maintaining them as separate modules adds operational overhead: two ArgoCD Applications, two namespaces, two cleanup functions, and duplicate Makefile targets. The ROADMAP already plans "Integrate benchmark results logging to MLflow" (Phase 4), which further cements their shared scope.

EvalHub (RHOAI 3.4) lists GuideLLM as a provider, but integration is limited to REST API routing -- there is no `GuideLLMJob` CRD, and LMEvalJob only supports lm-evaluation-harness tasks. The standalone GuideLLM K8s Job remains necessary for advanced scenario control (profiles, rate sweeping, PVC results, per-scenario resource limits).

## Options Considered

### Option 1: Keep Separate Modules

- Pros: Independent deployment, isolated concerns, simpler charts
- Cons: Operational overhead, no shared namespace, duplicate patterns (CA bundles, Makefile structure), harder MLflow integration

### Option 2: Merge as Helm Subchart

- Pros: Technical separation within a single release
- Cons: Subchart complexity not used elsewhere in the project, unnecessary abstraction for resources sharing a namespace

### Option 3: Merge as Flat Templates with Value Toggles

- Pros: Consistent with every other module in the project, simple `benchmarks.enabled` toggle, single ArgoCD Application, natural path to MLflow integration, fewer files to maintain
- Cons: Evaluation chart grows larger (~16 templates), but consistent with maas-platform which has a similar number

## Decision

**Option 3**: merge benchmarks into evaluation as flat templates with `benchmarks.enabled` toggle in `values.yaml`. Single `evaluation` namespace. Single ArgoCD Application. Remove all standalone benchmarks Makefile targets (`deploy-benchmarks`, `undeploy-benchmarks`, `test-benchmarks`) -- only `deploy-evaluation` and `run-benchmark` remain.

## Consequences

- **Positive**: Fewer modules to maintain (4 instead of 5), single namespace, natural path to MLflow benchmark result integration, simplified ArgoCD and cleanup
- **Positive**: `make run-benchmark` continues to work for on-demand load testing
- **Negative**: Evaluation chart grows to ~16 templates (acceptable, consistent with maas-platform)
- **Review**: If RHOAI adds a `GuideLLMJob` CRD in future versions, revisit whether the standalone Job template can be replaced by a TrustyAI-managed CR
