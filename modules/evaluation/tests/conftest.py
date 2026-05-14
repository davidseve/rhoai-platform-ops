"""Shared fixtures for Evaluation E2E tests."""

import json
import os
import subprocess

import pytest

EVALUATION_NAMESPACE = os.getenv("EVALUATION_NAMESPACE", "evaluation")
EVALUATION_CHART_PATH = os.getenv(
    "EVALUATION_CHART_PATH",
    "modules/evaluation/charts/evaluation",
)


def _run(cmd: str, *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd, shell=True, capture_output=True, text=True, check=check
    )


@pytest.fixture(scope="session")
def oc():
    """Run an arbitrary ``oc`` command and return stdout (stripped)."""

    def _oc(cmd: str) -> str:
        result = _run(f"oc {cmd}")
        return result.stdout.strip()

    _oc("whoami")
    return _oc


@pytest.fixture(scope="session")
def oc_json(oc):
    """Run an ``oc get ... -o json`` command and return parsed dict."""

    def _oc_json(cmd: str) -> dict:
        out = oc(f"{cmd} -o json")
        return json.loads(out)

    return _oc_json


@pytest.fixture(scope="session")
def evaluation_namespace():
    return EVALUATION_NAMESPACE


@pytest.fixture(scope="session")
def chart_path():
    return EVALUATION_CHART_PATH


@pytest.fixture(scope="session")
def oc_token():
    result = _run("oc whoami -t", check=False)
    if result.returncode != 0:
        pytest.skip("Not logged into cluster")
    return result.stdout.strip()


@pytest.fixture(scope="session")
def evalhub_url(oc):
    host = oc("get route evalhub -n evaluation -o jsonpath='{.spec.host}'")
    return f"https://{host}"


@pytest.fixture(scope="session")
def mlflow_url(oc):
    host = oc("get route mlflow -n redhat-ods-applications -o jsonpath='{.spec.host}'")
    return f"https://{host}"
