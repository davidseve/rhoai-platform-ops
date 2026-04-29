---
description: "Add a new module/pillar to the project. Creates directory structure, ArgoCD app template, Makefile targets, cleanup function, and documentation."
user_invocable: true
---

# Add Module

Add a new module (pillar) to the project.

## Process

### 1. Gather Module Details

If the user provided a module name (e.g., "/add-module observability"), use it. Otherwise ask:

> **What is the name of the new module?** (lowercase, hyphen-separated)
> **Brief description of what this module does?**

### 2. Create Directory Structure

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

- `Chart.yaml`: apiVersion v2, set name and description
- `values.yaml`: commented defaults
- `conftest.py`: import shared fixtures pattern from `modules/maas/tests/conftest.py`
- `pytest.ini`: `testpaths = .`
- `requirements.txt`: `pytest>=8.0`, `requests>=2.31`

### 3. Add ArgoCD Application Template

Create `argocd/apps/templates/<name>-<component>.yaml` with module enable guard, sync-wave, and standard sync policy.

### 4. Add Module Toggle

Add to `argocd/apps/values.yaml`:
```yaml
  <name>:
    enabled: false
```

### 5. Add Makefile Targets

Use the `python-venv-tests` pattern:

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

Add new targets to `deploy-all`, `test-all`, and `undeploy-all`.

### 6. Add Cluster Cleanup Function

Add `cleanup_<name>` function to `scripts/cluster-cleanup.sh`:

```bash
cleanup_<name>() {
  log "=== <Name>: Cleaning up ==="
  # 1. Delete custom resources (CRs) first
  # 2. Delete namespaced resources
  # 3. Delete cluster-scoped resources
  # 4. Delete namespaces (with wait_ns_gone for stuck ones)
}
```

### 7. Update Documentation

- Add module to `docs/PROJECT-STRUCTURE.md`
- Add module to `AGENTS.md` and `CLAUDE.md`

### 8. Create Initial ADR

Use the `/adr` skill to document the module's purpose and key technology choices.

### 9. Verify

```bash
helm template modules/<name>/charts/<chart>
```
