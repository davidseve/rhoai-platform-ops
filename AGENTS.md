# AGENTS.md

This file provides guidance to AI coding agents (Cursor, Claude Code, etc.) when working with this repository.

## Project Overview

RHOAI Platform Operations -- a modular GitOps repository for deploying and operating Red Hat OpenShift AI (RHOAI) infrastructure. Each module (database, MaaS, observability, evaluation) is independently deployable via Helm or ArgoCD. The project prioritizes Red Hat products, Helm-first validation, idempotent tests, and Architecture Decision Records for every non-obvious choice.

**Maturity:** Database, MaaS, observability, and evaluation modules deployed and tested

## Quick Commands

```bash
# Database module (shared PostgreSQL)
make deploy-database      # Helm install shared PostgreSQL
make undeploy-database    # Helm uninstall database

# Observability module
make deploy-observability # Helm install Grafana Operator + Grafana instance
make test-observability   # pytest modules/observability/tests/
make undeploy-observability # Helm uninstall observability

# MaaS module
make deploy-maas          # Helm install operators + platform + models
make deploy-maas GRAFANA_ENABLED=true  # Include Grafana dashboards
make test-maas            # pytest modules/maas/tests/
make undeploy-maas        # Helm uninstall + cleanup

# Full stack
make deploy-all           # Deploy observability + MaaS (with dashboards)
make test-all             # Run all module tests
make undeploy-all         # Undeploy everything

# ArgoCD (stable deployment)
make deploy-argocd        # Apply app-of-apps
make wait-healthy         # Wait for all ArgoCD apps Synced+Healthy and pods Ready
make bootstrap-argocd     # deploy-argocd + wait-healthy + test-all (full pipeline)
make status               # Check ArgoCD sync status
make argocd-branch-current # Point ArgoCD manifests to the current git branch
make argocd-branch-main   # Point ArgoCD manifests back to main
make argocd-branch BRANCH=feat/my-branch # Point ArgoCD manifests to an explicit branch

# Evaluation module (includes EvalHub, MLflow, GuideLLM benchmarks)
make deploy-evaluation    # Helm install EvalHub + MLflow + benchmarks infra
make run-evaluation EVAL_TASK=arc_easy EVAL_LIMIT=10  # Run LMEvalJob quality evaluation
make run-benchmark BENCHMARK_SCENARIO=gateway BENCHMARK_TARGET=https://...  # Gateway (default)
make run-benchmark BENCHMARK_SCENARIO=baseline   # Direct to model (no gateway)
make run-benchmark BENCHMARK_SCENARIO=stress BENCHMARK_TARGET=https://...   # Sweep auto-discovery
make run-benchmark BENCHMARK_SCENARIO=slo BENCHMARK_TARGET=https://...      # Constant 4 RPS
make test-evaluation      # pytest modules/evaluation/tests/
make undeploy-evaluation  # Helm uninstall evaluation

# Cluster cleanup
make cluster-cleanup      # Remove ALL resources (skip confirmation)
make cluster-cleanup-maas # Remove only MaaS resources
make cluster-cleanup-observability # Remove only observability resources
make cluster-cleanup-evaluation # Remove only evaluation resources (includes benchmarks)
make cluster-cleanup-database # Remove only database resources
make cluster-cleanup-dry  # Dry-run: show what would be deleted

# Validation
make template             # helm template for all charts (dry-run)
make lint                 # Helm lint + YAML validation
```

## Architecture

### Module Structure

```
modules/
  database/               # Shared PostgreSQL for platform services (MaaS API, MLflow, EvalHub)
    charts/
      database/           # Deployment, Service, Secret (maas-db in redhat-ods-applications)

  observability/          # Grafana, Tracing (OTel + Tempo), UWM, dashboards
    charts/
      operators/          # Grafana, OTel, Tempo Operator subscriptions, UWM ConfigMap
      grafana/            # Grafana CR, SA, RBAC, Thanos + Tempo datasources, dashboards
      tracing/            # TempoMonolithic CR, OpenTelemetryCollector CR, ServiceMonitor
    tests/                # E2E tests (Grafana, datasource, metrics, tracing)
    docs/                 # OBSERVABILITY.md

  maas/                   # Models-as-a-Service (RHOAI + Kuadrant)
    charts/
      operators/          # RHOAI, Kuadrant, LeaderWorkerSet operators
      maas-platform/      # DSCI, DSC, Gateway, Route, tiers, monitoring, vLLM PodMonitor/SLO, dashboards
      maas-model/         # LLMInferenceService, RBAC, rate limits
    tests/                # E2E tests (inference, in-cluster, governance)
    docs/                 # Architecture, Gateway, troubleshooting

  evaluation/             # Unified LLM evaluation: EvalHub (quality), MLflow (tracking), GuideLLM (performance)
    charts/
      evaluation/         # EvalHub CR, MLflow CR, GuideLLM Job, DB secrets, routes, CA bundles
    tests/                # E2E tests (template validation + cluster infra)
    docs/                 # EVALUATION.md, BENCHMARKS.md
```

### ArgoCD App-of-Apps

```
argocd/
  app-of-apps.yaml        # Root Application
  apps/
    Chart.yaml
    values.yaml            # Module toggles (modules.maas.enabled, etc.)
    templates/             # One Application per component
```

Each ArgoCD Application template uses `repoURL` and `targetRevision` from values (not hardcoded) and is wrapped in a module enable guard.

### Helm-First Workflow

1. Develop chart in `modules/<name>/charts/<chart>/`
2. Validate: `helm template modules/<name>/charts/<chart>`
3. Test on-cluster: `helm install <name> modules/<name>/charts/<chart>`
4. Run tests: `make test-<name>`
5. Once stable, add ArgoCD Application template and enable in values

## Key Conventions

### Red Hat Priority

Always use Red Hat products first:
- **RHOAI** for model serving (LLMInferenceService)
- **Kuadrant / RHCL** for API governance (AuthPolicy, RateLimitPolicy, TokenRateLimitPolicy)
- **Red Hat build of OpenTelemetry** for tracing
- **Cluster Observability Operator** for monitoring
- Community projects only when Red Hat doesn't cover the need

### Testing

- Every module has `tests/` with pytest
- Tests are idempotent (run N times), robust, easy to execute
- Naming: `test_NN_<description>.py` for file ordering
- Run: `make test-<module>` or `cd modules/<module>/tests && pytest -v`

### ADRs

Architecture Decision Records in `docs/adr/`. Use the `adr` skill to create new ones.

### Tier System (MaaS)

Tiers (`free`, `premium`) are defined as a map in `modules/maas/charts/maas-model/values.yaml`. Each tier specifies request and token rate limits. The tier names are a cross-chart contract with `maas-platform/values.yaml`.

## Key Integration Points

- **LLM Serving:** RHOAI LLMInferenceService (KServe + vLLM)
- **API Gateway:** Kubernetes Gateway API via Kuadrant
- **Auth:** Kuadrant AuthPolicy with KubernetesTokenReview (RHOAI 3.4+)
- **Rate Limiting:** MaaSSubscription + controller-managed TokenRateLimitPolicy (see [ADR-0005](docs/adr/0005-maas-subscription-model.md))
- **Monitoring:** OpenShift User Workload Monitoring (Prometheus, ServiceMonitor, PodMonitor)
- **Tracing:** Red Hat build of OpenTelemetry + Tempo (see [ADR-0004](docs/adr/0004-tracing-stack.md))
- **Dashboards:** Grafana Operator with OpenShift OAuth proxy (see [ADR-0003](docs/adr/0003-grafana-operator.md))
- **Database:** Shared PostgreSQL 16 in redhat-ods-applications (used by MaaS API, MLflow, EvalHub)
- **Benchmarks:** GuideLLM v0.6.0+ as K8s Job within evaluation module (infra via ArgoCD, Jobs on-demand)
- **Evaluation:** EvalHub (TrustyAI) + MLflow tracking server (RHOAI 3.4 Tech Preview)
- **GitOps:** ArgoCD with app-of-apps pattern

## Claude Code Skills

- `/add-module` -- Add a new module/pillar to the project
- `/deploy-module` -- Deploy a module via Helm or ArgoCD
- `/adr` -- Create an Architecture Decision Record
- `/status` -- Run project health check
- `/python-venv-tests` -- Add/update Makefile test targets with ephemeral venv (create, install, run, cleanup)
- `/cluster-bootstrap` -- Bootstrap a fresh cluster: deploy all modules in order and run tests to validate
- `/cluster-cleanup` -- Remove all deployed resources from the cluster (reverse order, handles stuck finalizers)
- `/push-and-pr` -- Push changes to a new branch and create a pull request
- `/switch-argocd-branch` -- Point ArgoCD app-of-apps and child apps to `main` or the current working branch

## Detailed Documentation

- [Project Structure](docs/PROJECT-STRUCTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Observability](modules/observability/docs/OBSERVABILITY.md)
- [MaaS Architecture](modules/maas/docs/ARCHITECTURE.md)
- [Gateway and Route](modules/maas/docs/GATEWAY-AND-ROUTE.md)
- [Evaluation](modules/evaluation/docs/EVALUATION.md)
- [Benchmarks](modules/evaluation/docs/BENCHMARKS.md)
- [ADRs](docs/adr/)
