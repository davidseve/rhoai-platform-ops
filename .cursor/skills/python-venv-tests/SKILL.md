---
description: Add or update a Makefile test target so it creates a temporary Python virtual environment, installs dependencies, runs pytest, and cleans up the venv afterwards. Use when adding test targets for new modules or fixing existing ones.
user_invocable: true
---

# Python Venv Test Targets

Ensure every `test-<module>` Makefile target uses an ephemeral virtual environment so that:
- Tests never pollute the system Python.
- Dependencies are always fresh from `requirements.txt`.
- The venv is removed after the run (even on failure).

## Pattern

Each test target must follow this template:

```makefile
PYTHON ?= python3

.PHONY: test-<module>
test-<module>: ## Run <module> tests
	$(PYTHON) -m venv modules/<module>/tests/.venv
	modules/<module>/tests/.venv/bin/pip install -q -r modules/<module>/tests/requirements.txt
	modules/<module>/tests/.venv/bin/pytest modules/<module>/tests/ -v; \
	  rc=$$?; rm -rf modules/<module>/tests/.venv; exit $$rc
```

### Key details

1. **Create** the venv inside the module's `tests/` directory (`.venv`).
2. **Install** dependencies using the venv's own `pip`.
3. **Run** pytest using the venv's interpreter.
4. **Capture** the exit code (`rc=$$?`) so the cleanup still runs on test failure.
5. **Remove** the `.venv` directory unconditionally.
6. **Propagate** the original exit code (`exit $$rc`) so `make` reports the correct status.

### .gitignore

Make sure `modules/<module>/tests/.gitignore` (or the root `.gitignore`) contains `.venv/` so the virtual environment is never committed.

## Process

### 1. Identify targets

Find all `test-*` targets in the Makefile that use `pip install` or `pytest` directly.

### 2. Rewrite each target

Replace the existing commands with the venv pattern above, adapting the module name and paths.

### 3. Add PYTHON variable

If not already present, add `PYTHON ?= python3` near the top of the Makefile with the other tool variables.

### 4. Verify

Run `make test-<module>` and confirm:
- The `.venv` is created during the run.
- Tests execute correctly.
- The `.venv` is removed after completion (both on success and failure).
