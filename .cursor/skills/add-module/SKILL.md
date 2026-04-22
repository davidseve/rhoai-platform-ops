---
description: Add a new module/pillar to the rhoai-platform-ops project. Creates the directory structure, ArgoCD app template, Makefile targets, and initial documentation.
user_invocable: true
---

# Add Module

Add a new module (pillar) to the project.

## Process

### 1. Gather Module Details

If the user provided a module name (e.g., "add module observability"), use it. Otherwise ask:

> **What is the name of the new module?** (lowercase, hyphen-separated, e.g., "observability", "benchmarks")

Then ask:

> **Brief description of what this module does?**

### 2. Create Directory Structure

Create the following under `modules/<name>/`:

```
modules/<name>/
  charts/
    <chart-name>/
      Chart.yaml
      values.yaml
      templates/
  tests/
    conftest.py
    pytest.ini
    requirements.txt
  docs/
    <NAME>.md
```

- `Chart.yaml`: Use apiVersion v2, set name and description
- `values.yaml`: Add commented defaults
- `conftest.py`: Import shared fixtures pattern from `modules/maas/tests/conftest.py`
- `pytest.ini`: Set `testpaths = .`
- `requirements.txt`: Start with `pytest>=8.0`, `requests>=2.31`

### 3. Add ArgoCD Application Template

Create `argocd/apps/templates/<name>-<component>.yaml`:

```yaml
{{- if .Values.modules.<name>.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <name>-<component>
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "<appropriate-wave>"
spec:
  project: default
  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: {{ .Values.targetRevision }}
    path: modules/<name>/charts/<chart>
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
      - SkipDryRunOnMissingResource=true
{{- end }}
```

### 4. Add Module Toggle

Add to `argocd/apps/values.yaml` under `modules:`:

```yaml
  <name>:
    enabled: false
```

### 5. Add Makefile Targets

Add to the root `Makefile`. Use the `python-venv-tests` skill pattern for test targets:

```makefile
deploy-<name>:
	$(HELM) upgrade --install <name> modules/<name>/charts/<chart> -n <namespace> --create-namespace

test-<name>:
	$(PYTHON) -m venv modules/<name>/tests/.venv
	modules/<name>/tests/.venv/bin/pip install -q -r modules/<name>/tests/requirements.txt
	modules/<name>/tests/.venv/bin/pytest modules/<name>/tests/ -v; \
	  rc=$$?; rm -rf modules/<name>/tests/.venv; exit $$rc

undeploy-<name>:
	-$(HELM) uninstall <name> -n <namespace>
```

Also add the new targets to `deploy-all`, `test-all`, and `undeploy-all`.

### 6. Add Cluster Cleanup Function

Add a `cleanup_<name>` function to `scripts/cluster-cleanup.sh` that removes all resources created by this module (CRs, namespaces, cluster-scoped resources). Follow the pattern of existing functions:

```bash
cleanup_<name>() {
  log "=== <Name>: Cleaning up ==="
  # 1. Delete custom resources (CRs) first
  # 2. Delete namespaced resources
  # 3. Delete cluster-scoped resources
  # 4. Delete namespaces (with wait_ns_gone for stuck ones)
}
```

Then add the function call to `main()` before the marker comment.

### 7. Update Documentation

- Add module to `docs/PROJECT-STRUCTURE.md`
- Add module to `AGENTS.md`: quick commands, architecture, skills if new ones were created

### 8. Create Initial ADR

Use the `adr` skill to create an ADR documenting the motivation for this module and key technology choices.

### 9. Verify

Run `helm template modules/<name>/charts/<chart>` to validate the chart renders.
