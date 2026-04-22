---
description: Run a project health check across all modules. Validates Helm charts, runs tests, and reports a pass/fail dashboard.
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
```

Capture pass/fail for each chart.

### 2. ArgoCD App-of-Apps Validation

```bash
helm template argocd/apps
```

Verify all Application templates render correctly.

### 3. Module Tests

For each module with tests, run the test suite:

```bash
make test-maas
# ... other enabled modules
```

Capture pass/fail and test counts.

### 4. Report Dashboard

Present results:

```markdown
## Project Health

| Check | Status | Details |
|-------|--------|---------|
| Helm: maas/operators | PASS/FAIL | <error or "renders clean"> |
| Helm: maas/maas-platform | PASS/FAIL | <error or "renders clean"> |
| Helm: maas/maas-model | PASS/FAIL | <error or "renders clean"> |
| Helm: argocd/apps | PASS/FAIL | <error or "renders clean"> |
| Tests: maas | PASS/FAIL | <passed>/<total> tests |

**Overall: HEALTHY / NEEDS ATTENTION / FAILING**

### Issues
[List any failing checks with key error details]

### Suggestions
[Actionable next steps to fix any failures]
```

If a module is not yet implemented (placeholder only), show it as `SKIPPED -- not yet implemented`.

### 5. Git Status

```markdown
### Git
- **Branch:** <current branch>
- **Ahead/behind:** <ahead>/<behind> vs <tracking branch>
- **Uncommitted changes:** <count> files modified, <count> untracked
```
