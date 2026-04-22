# AGENTS.md

This file provides guidance to AI coding agents (Cursor, Claude Code, etc.) when working with this repository.

## Project Overview

RHOAI Platform Operations -- a modular GitOps repository for deploying and operating Red Hat OpenShift AI (RHOAI) infrastructure. Each module (MaaS, observability, benchmarks, evaluation) is independently deployable via Helm or ArgoCD. The project prioritizes Red Hat products, Helm-first validation, idempotent tests, and Architecture Decision Records for every non-obvious choice.

**Maturity:** MVP (MaaS module production-ready; other modules in progress)

## Quick Commands

```bash
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
make status               # Check ArgoCD sync status

# Cluster cleanup
make cluster-cleanup      # Remove ALL resources (skip confirmation)
make cluster-cleanup-maas # Remove only MaaS resources
make cluster-cleanup-observability # Remove only observability resources
make cluster-cleanup-dry  # Dry-run: show what would be deleted

# Validation
make template             # helm template for all charts (dry-run)
make lint                 # Helm lint + YAML validation
```

## Architecture

### Module Structure

```
modules/
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

  benchmarks/             # [Planned] Load testing with inference-perf
  evaluation/             # [Planned] MLflow tracking server
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
- **Auth:** Kuadrant AuthPolicy with tier-based identity
- **Rate Limiting:** Kuadrant RateLimitPolicy + TokenRateLimitPolicy
- **Monitoring:** OpenShift User Workload Monitoring (Prometheus, ServiceMonitor, PodMonitor)
- **Tracing:** Red Hat build of OpenTelemetry + Tempo (see [ADR-0004](docs/adr/0004-tracing-stack.md))
- **Dashboards:** Grafana Operator with OpenShift OAuth proxy (see [ADR-0003](docs/adr/0003-grafana-operator.md))
- **GitOps:** ArgoCD with app-of-apps pattern

## Cursor Skills

- `add-module` -- Add a new module/pillar to the project
- `deploy-module` -- Deploy a module via Helm or ArgoCD
- `adr` -- Create an Architecture Decision Record
- `status` -- Run project health check
- `python-venv-tests` -- Add/update Makefile test targets with ephemeral venv (create, install, run, cleanup)
- `cluster-bootstrap` -- Bootstrap a fresh cluster: deploy all modules in order and run tests to validate
- `cluster-cleanup` -- Remove all deployed resources from the cluster (reverse order, handles stuck finalizers)
- `push-and-pr` -- Push changes to a new branch and create a pull request

## Detailed Documentation

- [Project Structure](docs/PROJECT-STRUCTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Observability](modules/observability/docs/OBSERVABILITY.md)
- [MaaS Architecture](modules/maas/docs/ARCHITECTURE.md)
- [Gateway and Route](modules/maas/docs/GATEWAY-AND-ROUTE.md)
- [ADRs](docs/adr/)
