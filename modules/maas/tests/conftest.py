"""Shared fixtures for MaaS E2E tests.

Requires: `oc` CLI logged into the target cluster.

All configuration is via env vars with sensible defaults.
Set MAAS_MODEL2_NAME="" to skip model-2 tests.
"""

import json
import os
import subprocess
import ssl

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ---------------------------------------------------------------------------
# Configuration (env vars with defaults matching charts/values.yaml)
# ---------------------------------------------------------------------------

MODEL_NAME = os.getenv("MAAS_MODEL_NAME", "tinyllama-test")
MODEL2_NAME = os.getenv("MAAS_MODEL2_NAME", "granite-2b")
MODEL_NAMESPACE = os.getenv("MAAS_MODEL_NAMESPACE", "models-as-a-service")
GATEWAY_NAME = os.getenv("MAAS_GATEWAY_NAME", "maas-default-gateway")
GATEWAY_NAMESPACE = os.getenv("MAAS_GATEWAY_NAMESPACE", "openshift-ingress")
GATEWAY_CLASS = os.getenv("MAAS_GATEWAY_CLASS", "data-science-gateway-class")


def _run(cmd: str, *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd, shell=True, capture_output=True, text=True, check=check
    )


# ---------------------------------------------------------------------------
# oc helpers
# ---------------------------------------------------------------------------

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
    """Run an ``oc get … -o json`` command and return parsed dict."""

    def _oc_json(cmd: str) -> dict:
        out = oc(f"{cmd} -o json")
        return json.loads(out)

    return _oc_json


# ---------------------------------------------------------------------------
# Cluster / MaaS coordinates
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def maas_host(oc):
    """Discover the Route hostname from the cluster."""
    return oc(
        f"get route {GATEWAY_NAME} -n {GATEWAY_NAMESPACE} "
        "-o jsonpath='{.spec.host}'"
    ).strip("'")


@pytest.fixture(scope="session")
def maas_url(maas_host):
    return f"https://{maas_host}"


@pytest.fixture(scope="session")
def gateway_internal_host():
    svc = f"{GATEWAY_NAME}-{GATEWAY_CLASS}"
    return f"{svc}.{GATEWAY_NAMESPACE}.svc.cluster.local"


@pytest.fixture(scope="session")
def gateway_internal_url(gateway_internal_host):
    return f"https://{gateway_internal_host}"


# ---------------------------------------------------------------------------
# Authentication tokens
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def test_group_membership(oc):
    """Verify current user is in a Kubernetes group that matches a MaaSSubscription."""
    user = oc("whoami")
    return user


@pytest.fixture(scope="session")
def oc_token(oc):
    """Current ``oc`` session token (admin)."""
    return oc("whoami -t")


@pytest.fixture(scope="session")
def maas_token(oc_token):
    """OCP token for model listing and API key generation.

    RHOAI 3.4 GA: OCP tokens are accepted ONLY for /v1/models (listing).
    Inference requires API keys (sk-oai-*). Use maas_api_key for inference.
    """
    return oc_token


@pytest.fixture(scope="session")
def maas_api_key(maas_url, oc_token, model_name, test_group_membership):
    """Generate a MaaS API key bound to the primary model's premium subscription."""
    resp = requests.post(
        f"{maas_url}/maas-api/v1/api-keys",
        headers={
            "Authorization": f"Bearer {oc_token}",
            "Content-Type": "application/json",
        },
        json={
            "name": "e2e-test-key",
            "expiration": "30m",
            "subscription": f"{model_name}-premium",
        },
        verify=False,
        timeout=15,
    )
    resp.raise_for_status()
    data = resp.json()
    assert data.get("key"), "API key is empty"
    return data


@pytest.fixture(scope="session")
def maas_free_api_key(maas_url, oc_token, model_name):
    """Generate an API key explicitly bound to the free-tier subscription."""
    resp = requests.post(
        f"{maas_url}/maas-api/v1/api-keys",
        headers={
            "Authorization": f"Bearer {oc_token}",
            "Content-Type": "application/json",
        },
        json={
            "name": "e2e-free-tier-key",
            "expiration": "30m",
            "subscription": f"{model_name}-free",
        },
        verify=False,
        timeout=15,
    )
    if resp.status_code not in (200, 201):
        pytest.skip(f"Could not create free-tier API key: {resp.status_code} {resp.text[:200]}")
    data = resp.json()
    if "free" not in data.get("subscription", ""):
        pytest.skip(f"API key not bound to free subscription: {data.get('subscription')}")
    return data


@pytest.fixture(scope="session")
def maas_api_key_model2(maas_url, oc_token, model2_name, test_group_membership):
    """Generate a MaaS API key bound to the second model's premium subscription."""
    resp = requests.post(
        f"{maas_url}/maas-api/v1/api-keys",
        headers={
            "Authorization": f"Bearer {oc_token}",
            "Content-Type": "application/json",
        },
        json={
            "name": "e2e-test-key-model2",
            "expiration": "30m",
            "subscription": f"{model2_name}-premium",
        },
        verify=False,
        timeout=15,
    )
    resp.raise_for_status()
    data = resp.json()
    assert data.get("key"), "API key for model2 is empty"
    return data


# ---------------------------------------------------------------------------
# Helpers exposed as fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def model_name():
    return MODEL_NAME


@pytest.fixture(scope="session")
def model_namespace():
    return MODEL_NAMESPACE


@pytest.fixture(scope="session")
def gateway_name():
    return GATEWAY_NAME


@pytest.fixture(scope="session")
def gateway_namespace():
    return GATEWAY_NAMESPACE


@pytest.fixture(scope="session")
def inference_path():
    """URL path segment for chat completions (model 1)."""
    return f"/{MODEL_NAMESPACE}/{MODEL_NAME}/v1/chat/completions"


@pytest.fixture(scope="session")
def completions_path():
    """URL path segment for text completions (model 1)."""
    return f"/{MODEL_NAMESPACE}/{MODEL_NAME}/v1/completions"


@pytest.fixture(scope="session")
def chat_payload():
    """Minimal chat completion request body (model 1)."""
    return {
        "model": MODEL_NAME,
        "messages": [{"role": "user", "content": "Say hello in one word"}],
        "max_tokens": 20,
    }


@pytest.fixture(scope="session")
def completions_payload():
    """Minimal text completion request body (model 1)."""
    return {
        "model": MODEL_NAME,
        "prompt": "Once upon a time",
        "max_tokens": 20,
    }


# ---------------------------------------------------------------------------
# Model 2 fixtures (skip automatically if not deployed)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def model2_available(oc):
    """Return True if a second model is configured and deployed."""
    if not MODEL2_NAME:
        return False
    result = _run(
        f"oc get httproute {MODEL2_NAME}-kserve-route -n {MODEL_NAMESPACE}",
        check=False,
    )
    return result.returncode == 0


@pytest.fixture(scope="session")
def model2_name(model2_available):
    if not model2_available:
        pytest.skip("Model 2 not deployed")
    return MODEL2_NAME


@pytest.fixture(scope="session")
def inference_path_model2(model2_name):
    return f"/{MODEL_NAMESPACE}/{model2_name}/v1/chat/completions"


@pytest.fixture(scope="session")
def chat_payload_model2(model2_name):
    return {
        "model": model2_name,
        "messages": [{"role": "user", "content": "Say hello in one word"}],
        "max_tokens": 20,
    }


# ---------------------------------------------------------------------------
# Feature detection helpers
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def has_telemetrypolicy(oc):
    result = _run(
        f"oc get telemetrypolicy -n {GATEWAY_NAMESPACE} --no-headers",
        check=False,
    )
    return result.returncode == 0 and result.stdout.strip() != ""
