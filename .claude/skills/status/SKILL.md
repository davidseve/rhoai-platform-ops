---
description: "Run a project health check across all modules. Validates Helm charts, runs tests, and reports a pass/fail dashboard."
user_invocable: true
---

# Project Status Check

Run all project quality gates and report a health dashboard.

## Process

### 1. Helm Template Validation

For each module with charts, run `helm template`:

```bash
helm template modules/maas/charts/operators
helm template modules/maas/charts/maas-platform
helm template modules/maas/charts/maas-model
helm template modules/observability/charts/operators
helm template modules/observability/charts/grafana
helm template modules/observability/charts/tracing
```

### 2. ArgoCD App-of-Apps Validation

```bash
helm template argocd/apps
```

### 3. Module Tests

```bash
make test-maas
make test-observability
```

### 4. Report Dashboard

```markdown
## Project Health

| Check | Status | Details |
|-------|--------|---------|
| Helm: maas/operators | PASS/FAIL | <error or "renders clean"> |
| Helm: maas/maas-platform | PASS/FAIL | ... |
| Helm: maas/maas-model | PASS/FAIL | ... |
| Helm: observability/operators | PASS/FAIL | ... |
| Helm: observability/grafana | PASS/FAIL | ... |
| Helm: observability/tracing | PASS/FAIL | ... |
| Helm: argocd/apps | PASS/FAIL | ... |
| Tests: maas | PASS/FAIL | <passed>/<total> tests |
| Tests: observability | PASS/FAIL | <passed>/<total> tests |

**Overall: HEALTHY / NEEDS ATTENTION / FAILING**
```

If a module is not yet implemented, show it as `SKIPPED -- not yet implemented`.

### 5. Git Status

```markdown
### Git
- **Branch:** <current branch>
- **Ahead/behind:** <ahead>/<behind> vs <tracking branch>
- **Uncommitted changes:** <count> files
```
