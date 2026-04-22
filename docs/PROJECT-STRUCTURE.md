# Project Structure

## Overview

This repository uses a modular structure where each operational concern (MaaS, observability, benchmarks, evaluation) is an independent module. Modules can be deployed individually or together.

## Directory Layout

```
rhoai-platform-ops/
  argocd/                     # GitOps deployment
    app-of-apps.yaml          # Root ArgoCD Application
    apps/                     # Helm chart that generates child Applications
      Chart.yaml
      values.yaml             # Module toggles and cluster config
      templates/              # One Application template per component

  modules/                    # Operational modules
    <name>/
      charts/                 # Helm charts for this module
        <chart>/
          Chart.yaml
          values.yaml
          templates/
      tests/                  # pytest test suite
        conftest.py           # Shared fixtures
        test_NN_*.py          # Test files (ordered by prefix)
        pytest.ini
        requirements.txt
      docs/                   # Module-specific documentation

  docs/                       # Cross-module documentation
    ROADMAP.md                # Master plan and pillar overview
    PROJECT-STRUCTURE.md      # This file
    adr/                      # Architecture Decision Records

  .cursor/                    # AI agent configuration
    rules/                    # Cursor rules (conventions, patterns)
    skills/                   # Cursor skills (guided workflows)

  AGENTS.md                   # Project context for AI agents
  Makefile                    # Per-module and global targets
  README.md                   # Short quickstart
```

## How Modules Work

### Independence

Each module is self-contained. You can deploy MaaS without observability, or observability without benchmarks. The ArgoCD app-of-apps uses `enabled` flags:

```yaml
# argocd/apps/values.yaml
modules:
  maas:
    enabled: true
  observability:
    enabled: false    # Enable when ready
```

### Deployment Flow

```
helm template (validate) --> helm install (test) --> ArgoCD (stable)
```

1. **Helm template**: Validate chart renders without errors
2. **Helm install**: Deploy directly to cluster for testing
3. **ArgoCD**: Enable in app-of-apps for stable GitOps deployment

### Adding a New Module

Use the `add-module` Cursor skill, or follow these steps:

1. Create `modules/<name>/` with `charts/`, `tests/`, `docs/`
2. Add ArgoCD Application template in `argocd/apps/templates/`
3. Add toggle to `argocd/apps/values.yaml`
4. Add Makefile targets: `deploy-<name>`, `test-<name>`, `undeploy-<name>`
5. Update this file and `AGENTS.md`
6. Create an ADR documenting the module's purpose and key choices

## Current Modules

### maas (Ready)

Models-as-a-Service deployment using RHOAI and Kuadrant.

| Chart | Description |
|-------|-------------|
| `operators` | RHOAI, Kuadrant, LeaderWorkerSet operator subscriptions |
| `maas-platform` | DSCInitialization, DataScienceCluster, Gateway, Route, tiers |
| `maas-model` | LLMInferenceService, RBAC, RateLimitPolicy, TokenRateLimitPolicy |

### observability (Planned)

Grafana dashboards, vLLM metrics collection, alerting rules.

### benchmarks (Planned)

Load testing harness using inference-perf with MLflow tracking.

### evaluation (Planned)

MLflow Tracking Server for experiment logging and model evaluation.
