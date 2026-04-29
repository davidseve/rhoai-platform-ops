---
description: "Add or update Makefile test targets to use ephemeral Python virtual environments. Ensures tests never pollute system Python."
user_invocable: true
---

# Python Venv Test Targets

Ensure every `test-<module>` Makefile target uses an ephemeral virtual environment.

## Pattern

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

1. **Create** the venv inside the module's `tests/` directory (`.venv`)
2. **Install** dependencies using the venv's own `pip`
3. **Run** pytest using the venv's interpreter
4. **Capture** the exit code (`rc=$$?`) so cleanup still runs on failure
5. **Remove** the `.venv` directory unconditionally
6. **Propagate** the original exit code (`exit $$rc`)

### .gitignore

Ensure `.venv/` is in `.gitignore`.

## Process

1. Find all `test-*` targets in the Makefile
2. Rewrite each target with the venv pattern above
3. Add `PYTHON ?= python3` if not already present
4. Verify with `make test-<module>`
