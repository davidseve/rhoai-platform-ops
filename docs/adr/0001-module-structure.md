# ADR-0001: Module Structure and Helm-First Workflow

## Status

Accepted

## Context

The RHOAI platform operations span multiple concerns: model serving (MaaS), observability, benchmarking, and evaluation. Initially all MaaS content lived in a single repository (`rhoai-maas-gitops`). As the scope expanded to include observability, tracing, load testing, and MLflow, we needed a structure that:

1. Allows incremental implementation (one pillar at a time)
2. Enables deploying only what you need (MaaS alone, or MaaS + observability)
3. Keeps the fast feedback loop when developing new charts
4. Supports stable GitOps deployment when ready

## Options Considered

### Option 1: Separate repositories per pillar
- **Pros:** Complete isolation, independent release cycles
- **Cons:** Cross-pillar coordination is harder, ArgoCD needs multiple repos, shared patterns duplicated

### Option 2: Monorepo with flat chart directories
- **Pros:** Simple structure, all charts at top level
- **Cons:** No logical grouping, unclear which charts belong together, test suites mixed

### Option 3: Monorepo with module directories
- **Pros:** Logical grouping per pillar, shared ArgoCD app-of-apps, independent tests per module, easy to add new modules
- **Cons:** Slightly deeper directory nesting

## Decision

Use **Option 3: Monorepo with module directories**. Each pillar lives under `modules/<name>/` with `charts/`, `tests/`, and `docs/` subdirectories. ArgoCD app-of-apps at the repo root uses `enabled` flags per module.

Additionally, adopt a **Helm-first workflow**: every chart is first validated with `helm template`, tested with `helm install`, and only added to ArgoCD once stable. This keeps the development feedback loop fast (seconds for `helm template` vs minutes for ArgoCD sync).

## Consequences

### Positive
- New pillars are added without touching existing modules
- Modules can be deployed independently (`make deploy-maas` without observability)
- Helm-first workflow catches template errors before they reach ArgoCD
- Tests per module can run independently

### Negative
- Chart paths in ArgoCD templates are longer (`modules/maas/charts/maas-model` vs `charts/maas-model`)
- Must maintain module enable guards in all ArgoCD Application templates

### Neutral
- Migrating from the old repo required updating all ArgoCD path references
