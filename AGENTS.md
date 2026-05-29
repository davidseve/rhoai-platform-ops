# AGENTS.md

This file provides guidance to AI coding agents (Cursor, Claude Code, etc.) when working with this repository.

## Project Overview

RHOAI Platform Operations -- a modular GitOps repository for deploying and operating Red Hat OpenShift AI (RHOAI) infrastructure. Each module (database, MaaS, observability, evaluation) is independently deployable via Helm or ArgoCD. The project prioritizes Red Hat products, Helm-first validation, idempotent tests, and Architecture Decision Records for every non-obvious choice.

**Maturity:** Database, MaaS, observability, evaluation, and model registry modules deployed and tested

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
make deploy-argocd        # Apply app-of-apps (auto-detects CLUSTER_DOMAIN from cluster)
make deploy-argocd CLUSTER_DOMAIN=apps.example.com  # Manual override
make wait-healthy         # Wait for all ArgoCD apps Synced+Healthy and pods Ready
make bootstrap-argocd     # deploy-argocd + wait-healthy + test-all (full pipeline)
make status               # Check ArgoCD sync status
make argocd-branch-current # Point ArgoCD manifests to the current git branch
make argocd-branch-main   # Point ArgoCD manifests back to main
make argocd-branch BRANCH=feat/my-branch # Point ArgoCD manifests to an explicit branch

# Evaluation module (EvalHub orchestrator + MLflow)
make deploy-evaluation    # Helm install EvalHub + MLflow
make evalhub-eval EVALHUB_BENCHMARK=arc_easy MODEL_URL=https://... EVAL_LIMIT=10  # Quality eval via EvalHub API
make evalhub-benchmark MODEL_URL=https://...  # Performance benchmark (GuideLLM throughput, max-seconds=30)
make evalhub-smoke MODEL_URL=https://...      # Smoke test: lm-eval limit=1, full pipeline validation
make evalhub-security MODEL_URL=https://...   # Security scan via Garak (GPU only — too slow on CPU)
make evalhub-status JOB_ID=<uuid>   # Check job status
make evalhub-jobs                   # List all evaluation jobs
make evalhub-providers              # List available providers and benchmarks
make evalhub-collections            # List benchmark collections
make test-evaluation      # pytest modules/evaluation/tests/
make undeploy-evaluation  # Helm uninstall evaluation

# Model Registry
make deploy-model-registry   # Helm install Model Registry + catalog
make undeploy-model-registry # Helm uninstall Model Registry

# Pre-flight & Cluster cleanup
make preflight-namespaces # Clear namespaces stuck in Terminating (auto-runs before bootstrap)
make cluster-cleanup      # Remove ALL resources (skip confirmation)
make cluster-cleanup-maas # Remove only MaaS resources
make cluster-cleanup-observability # Remove only observability resources
make cluster-cleanup-evaluation # Remove only evaluation resources
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
      maas-db/            # PostgreSQL for maas-api (deployed before platform)
      maas-platform/      # DSCI, DSC, Gateway, Route, tiers, monitoring, vLLM PodMonitor/SLO, dashboards
      maas-model/         # LLMInferenceService, RBAC, rate limits, catalog ConfigMap
      model-registry/     # RHOAI Model Registry CR (Kubeflow), DB secret
    tests/                # E2E tests (inference, in-cluster, governance, model registry)
    docs/                 # Architecture, Gateway, troubleshooting

  evaluation/             # Unified LLM evaluation: EvalHub (quality + performance), MLflow (tracking)
    charts/
      evaluation/         # EvalHub CR, MLflow CR, DB secrets, routes, CA bundles
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
- **Auth:** Kuadrant AuthPolicy with KubernetesTokenReview (RHOAI 3.4+) — PostSync self-healing for Istio race condition (see [ADR-0011](docs/adr/0011-kuadrant-istio-race-condition.md)). Production hardened: Limitador 2 replicas with resource limits, PDBs for Authorino and Limitador, auth timeout alerts (see [Gateway docs](modules/maas/docs/GATEWAY-AND-ROUTE.md#production-hardening)). Authorino sizing pending CRD support.
- **Rate Limiting:** MaaSSubscription + controller-managed TokenRateLimitPolicy (see [ADR-0005](docs/adr/0005-maas-subscription-model.md))
- **Monitoring:** OpenShift User Workload Monitoring (Prometheus, ServiceMonitor, PodMonitor)
- **Tracing:** Red Hat build of OpenTelemetry + Tempo with persistent PV storage + trace-based SLO alerts (see [ADR-0004](docs/adr/0004-tracing-stack.md))
- **Dashboards:** Grafana Operator with OpenShift OAuth proxy (see [ADR-0003](docs/adr/0003-grafana-operator.md))
- **Database:** Shared PostgreSQL 16 in redhat-ods-applications with dedicated databases per consumer (mlflow, evalhub, model_registry, maas)
- **Model Registry:** RHOAI Model Registry (Kubeflow) with PostgreSQL backend + declarative ConfigMap catalog (see [ADR-0010](docs/adr/0010-model-registry-postgresql.md))
- **Evaluation:** EvalHub (TrustyAI) as orchestrator via REST API — manages lm-eval, GuideLLM, Garak, Lighteval jobs and logs to MLflow automatically (see [ADR-0008](docs/adr/0008-evalhub-orchestrator.md))
- **Experiment Tracking:** MLflow tracking server (RHOAI MLflow Operator)
- **GitOps:** ArgoCD with app-of-apps pattern

## Agent Skills

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
- [Evaluation](docs/EVALUATION.md)
- [Benchmarks](docs/BENCHMARKS.md)
- [ADRs](docs/adr/)
