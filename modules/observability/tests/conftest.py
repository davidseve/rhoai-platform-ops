"""Shared fixtures for Observability E2E tests.

Requires: `oc` CLI logged into the target cluster.
"""

import json
import os
import subprocess

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

GRAFANA_NAMESPACE = os.getenv("GRAFANA_NAMESPACE", "observability")
GRAFANA_NAME = os.getenv("GRAFANA_NAME", "grafana")
MODEL_NAMESPACE = os.getenv("MAAS_MODEL_NAMESPACE", "models-as-a-service")
MAAS_MODEL_NAME = os.getenv("MAAS_MODEL_NAME", "tinyllama-test")
MAAS_GATEWAY_NAME = os.getenv("MAAS_GATEWAY_NAME", "maas-default-gateway")
MAAS_GATEWAY_NAMESPACE = os.getenv("MAAS_GATEWAY_NAMESPACE", "openshift-ingress")


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
def grafana_namespace():
    return GRAFANA_NAMESPACE


@pytest.fixture(scope="session")
def grafana_name():
    return GRAFANA_NAME


@pytest.fixture(scope="session")
def model_namespace():
    return MODEL_NAMESPACE


@pytest.fixture(scope="session")
def grafana_route_url(oc):
    """Grafana Route URL from the cluster."""
    host = oc(
        f"get route {GRAFANA_NAME}-route -n {GRAFANA_NAMESPACE} "
        "-o jsonpath='{.spec.host}'"
    ).strip("'")
    return f"https://{host}"


@pytest.fixture(scope="session")
def thanos_url():
    return "https://thanos-querier.openshift-monitoring.svc.cluster.local:9091"


@pytest.fixture(scope="session")
def tempo_url():
    return "http://tempo-tempo:3200"


@pytest.fixture(scope="session")
def collector_namespace():
    return "observability"


@pytest.fixture(scope="session")
def tracing_enabled(oc):
    """Auto-detect if model pods have OTEL tracing configured. Skip if not."""
    try:
        env_value = oc(
            f"get pods -n {MODEL_NAMESPACE} "
            "-l app.kubernetes.io/component=predictor "
            "-o jsonpath='{.items[0].spec.containers[0].env[?(@.name==\"OTEL_TRACES_EXPORTER\")].value}'"
        ).strip("'")
        if env_value != "otlp":
            pytest.skip("Tracing not enabled on model pods (OTEL_TRACES_EXPORTER != otlp)")
    except Exception:
        pytest.skip("Could not detect tracing status on model pods")


@pytest.fixture(scope="session")
def maas_url(oc):
    """MaaS gateway URL for inference requests."""
    host = oc(
        f"get route {MAAS_GATEWAY_NAME} -n {MAAS_GATEWAY_NAMESPACE} "
        "-o jsonpath='{.spec.host}'"
    ).strip("'")
    return f"https://{host}"


@pytest.fixture(scope="session")
def maas_token(oc):
    """Auth token for inference (oc session token)."""
    return oc("whoami -t")


@pytest.fixture(scope="session")
def maas_inference_path():
    """Inference URL path for the default model."""
    return f"/{MODEL_NAMESPACE}/{MAAS_MODEL_NAME}/v1/chat/completions"


@pytest.fixture(scope="session")
def grafana_sa_token(oc):
    """Read the Grafana SA token from the cluster."""
    import base64

    b64 = oc(
        f"get secret {GRAFANA_NAME}-sa-token -n {GRAFANA_NAMESPACE} "
        "-o jsonpath='{.data.token}'"
    ).strip("'")
    return base64.b64decode(b64).decode()
