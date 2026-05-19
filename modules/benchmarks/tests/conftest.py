"""Shared fixtures for Benchmarks E2E tests.

Requires: `oc` CLI logged into the target cluster (for cluster tests),
or just Helm installed (for template validation tests).
"""

import json
import os
import subprocess

import pytest

BENCHMARK_NAMESPACE = os.getenv("BENCHMARK_NAMESPACE", "benchmarks")
BENCHMARK_CHART_PATH = os.getenv(
    "BENCHMARK_CHART_PATH",
    "modules/benchmarks/charts/benchmarks",
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
def benchmark_namespace():
    return BENCHMARK_NAMESPACE


@pytest.fixture(scope="session")
def chart_path():
    return BENCHMARK_CHART_PATH
