---
description: "Python test conventions for module test suites."
globs:
  - "modules/**/tests/**/*.py"
---

# Python Test Conventions

## Framework

All tests use pytest. Each module has its own test suite under `modules/<name>/tests/`.

## Fixtures

Shared fixtures go in `conftest.py`:
- `oc` helper for running `oc` CLI commands
- Cluster-derived fixtures (URLs, tokens, domains)
- Use `@pytest.fixture(scope="session")` for expensive setup (tokens, URLs)

## Test Structure

Follow Arrange-Act-Assert:
```python
def test_model_responds_to_chat(maas_url, maas_token):
    # Arrange
    headers = {"Authorization": f"Bearer {maas_token}"}
    payload = {"model": "tinyllama", "messages": [{"role": "user", "content": "Hi"}]}

    # Act
    resp = requests.post(f"{maas_url}/v1/chat/completions", json=payload, headers=headers, verify=False)

    # Assert
    assert resp.status_code == 200
    assert resp.json()["choices"][0]["message"]["content"]
```

## Naming

- Files: `test_NN_<description>.py` (numeric prefix controls execution order)
- Functions: `test_<what_is_being_tested>` -- descriptive, readable

## Idempotency

Tests must be runnable multiple times without manual cleanup:
- Do not assume fresh state
- Do not leave resources that break subsequent runs
- Rate limit tests should account for existing counter state

## HTTP Requests

- Use `requests` library with `verify=False` for self-signed cluster certs
- Suppress warnings: `urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)`
- Use `ThreadPoolExecutor` for parallel/concurrent request tests

## Virtual Environment

Makefile `test-<module>` targets use an ephemeral venv:
1. Create `.venv` inside the module's `tests/` directory
2. Install deps with the venv's pip
3. Run pytest with the venv's interpreter
4. Remove `.venv` after the run (even on failure)

Never install test dependencies into the system Python.

## Dependencies

Keep `requirements.txt` minimal per module:
```
pytest>=8.0
requests>=2.31
pyyaml>=6.0
urllib3>=2.0
```
