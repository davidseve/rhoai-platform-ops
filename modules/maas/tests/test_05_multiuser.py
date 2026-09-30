"""Multi-user E2E tests — create a second user, verify per-user metrics.

Creates a temporary htpasswd user (maas-e2e-user), adds it to the
maas-test-users group, generates an API key via that user's token,
sends inference, and asserts that Limitador metrics carry a distinct
``user`` label so Grafana can show per-user usage breakdowns.

Uses the OAuth token-request API to obtain the second user's token
without switching the global ``oc`` context.

The user is cleaned up at the end of the module regardless of outcome.
"""

import base64
import json
import os
import subprocess
import time

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

MODEL_NAME = os.getenv("MAAS_MODEL_NAME", "tinyllama-test")
MODEL_NAMESPACE = os.getenv("MAAS_MODEL_NAMESPACE", "models-as-a-service")
E2E_USER = "maas-e2e-user"
E2E_PASSWORD = "MaasTest1!"
E2E_GROUP = "maas-test-users"


def _run(cmd: str, *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd, shell=True, capture_output=True, text=True, check=check,
    )


def _oc(cmd: str) -> str:
    result = _run(f"oc {cmd}")
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# Htpasswd user management (never switches oc context)
# ---------------------------------------------------------------------------

def _get_htpasswd() -> str:
    b64 = _oc(
        "get secret htpass-secret -n openshift-config "
        "-o jsonpath='{.data.htpasswd}'"
    ).strip("'")
    return base64.b64decode(b64).decode()


def _set_htpasswd(content: str):
    b64 = base64.b64encode(content.encode()).decode()
    _oc(
        f'patch secret htpass-secret -n openshift-config --type merge '
        f'-p \'{{"data":{{"htpasswd":"{b64}"}}}}\''
    )


def _add_user(username: str, password: str):
    current = _get_htpasswd()
    if f"{username}:" in current:
        return
    result = _run(f"htpasswd -nbB {username} {password}")
    new_line = result.stdout.strip()
    updated = current.rstrip("\n") + "\n" + new_line + "\n"
    _set_htpasswd(updated)


def _remove_user(username: str):
    current = _get_htpasswd()
    lines = [ln for ln in current.splitlines() if not ln.startswith(f"{username}:")]
    _set_htpasswd("\n".join(lines) + "\n")
    _run(f"oc delete user {username} --ignore-not-found", check=False)
    _run(f"oc delete identity htpasswd_provider:{username} --ignore-not-found", check=False)


def _get_user_token(username: str, password: str, retries: int = 18) -> str:
    """Obtain a bearer token via the OAuth authorize endpoint.

    Uses the ``oauth-openshift`` Route (not the API server) with basic
    auth to request an implicit-grant token. Does NOT switch the oc context.
    """
    oauth_host = _oc(
        "get route oauth-openshift -n openshift-authentication "
        "-o jsonpath='{.spec.host}'"
    ).strip("'")

    for attempt in range(retries):
        result = _run(
            f"curl -sku '{username}:{password}' "
            f"'https://{oauth_host}/oauth/authorize"
            f"?client_id=openshift-challenging-client"
            f"&response_type=token' "
            f"-D - -o /dev/null 2>&1",
            check=False,
        )
        for line in result.stdout.splitlines():
            if "access_token=" in line:
                token = line.split("access_token=")[1].split("&")[0]
                return token
        time.sleep(5)

    pytest.fail(f"Could not obtain token for {username} after {retries} retries")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def e2e_user_setup():
    """Create the E2E test user and add to groups.

    Adds the user to ``cluster-admins`` (required by MaaSSubscription
    owner.groups) and ``maas-test-users`` (free tier). Cleans up after.
    """
    _add_user(E2E_USER, E2E_PASSWORD)
    _run(f"oc adm groups add-users cluster-admins {E2E_USER} 2>&1", check=False)
    _run(f"oc adm groups add-users {E2E_GROUP} {E2E_USER} 2>&1", check=False)
    # Wait for OAuth to pick up htpasswd changes
    time.sleep(10)
    yield E2E_USER
    _remove_user(E2E_USER)
    _run(f"oc adm groups remove-users cluster-admins {E2E_USER} 2>&1", check=False)
    _run(f"oc adm groups remove-users {E2E_GROUP} {E2E_USER} 2>&1", check=False)


@pytest.fixture(scope="module")
def e2e_user_token(e2e_user_setup):
    """Obtain a bearer token for the E2E user (no oc login)."""
    return _get_user_token(E2E_USER, E2E_PASSWORD)


@pytest.fixture(scope="module")
def maas_url():
    host = _oc(
        "get route maas-default-gateway -n openshift-ingress "
        "-o jsonpath='{.spec.host}'"
    ).strip("'")
    return f"https://{host}"


@pytest.fixture(scope="module")
def admin_token():
    return _oc("whoami -t")


@pytest.fixture(scope="module")
def thanos_host():
    return _oc(
        "get route thanos-querier -n openshift-monitoring "
        "-o jsonpath='{.spec.host}'"
    ).strip("'")


@pytest.fixture(scope="module")
def e2e_user_api_key(maas_url, e2e_user_token):
    """Create an API key for the E2E user."""
    resp = requests.post(
        f"{maas_url}/maas-api/v1/api-keys",
        headers={
            "Authorization": f"Bearer {e2e_user_token}",
            "Content-Type": "application/json",
        },
        json={
            "name": "e2e-multiuser-key",
            "expiration": "30m",
            "subscription": f"{MODEL_NAME}-free",
        },
        verify=False,
        timeout=15,
    )
    assert resp.status_code in (200, 201), (
        f"API key creation failed: {resp.status_code} {resp.text[:300]}"
    )
    data = resp.json()
    assert data.get("key"), "E2E user API key is empty"
    return data


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestMultiUserInference:
    """Verify a second user can authenticate and generate distinct metrics."""

    def test_user_can_list_models(self, maas_url, e2e_user_token):
        """E2E user with K8s token can list models via /v1/models."""
        resp = requests.get(
            f"{maas_url}/v1/models",
            headers={"Authorization": f"Bearer {e2e_user_token}"},
            verify=False,
            timeout=15,
        )
        assert resp.status_code == 200, (
            f"Expected 200, got {resp.status_code}: {resp.text[:200]}"
        )
        models = resp.json().get("data", [])
        assert len(models) > 0, "No models returned"

    def test_user_can_create_api_key(self, e2e_user_api_key):
        """E2E user can create an API key."""
        assert e2e_user_api_key["key"].startswith("sk-oai-")

    def test_user_inference_returns_200(self, maas_url, e2e_user_api_key):
        """E2E user can perform inference via gateway with their API key."""
        resp = requests.post(
            f"{maas_url}/{MODEL_NAMESPACE}/{MODEL_NAME}/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {e2e_user_api_key['key']}",
                "Content-Type": "application/json",
            },
            json={
                "model": MODEL_NAME,
                "messages": [{"role": "user", "content": "Say hello"}],
                "max_tokens": 10,
            },
            verify=False,
            timeout=30,
        )
        assert resp.status_code == 200, (
            f"Inference failed with {resp.status_code}: {resp.text[:200]}"
        )
        data = resp.json()
        assert data.get("choices"), "No choices in inference response"


class TestPerUserMetrics:
    """Verify that Limitador metrics carry per-user labels."""

    def test_metrics_have_user_label(
        self, maas_url, e2e_user_api_key, admin_token, thanos_host,
    ):
        """After E2E user inference, authorized_calls should show
        distinct user labels for both 'redhat' and the E2E user."""
        # Send a few requests to ensure metrics are populated
        for _ in range(3):
            requests.post(
                f"{maas_url}/{MODEL_NAMESPACE}/{MODEL_NAME}/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {e2e_user_api_key['key']}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": MODEL_NAME,
                    "messages": [{"role": "user", "content": "Hi"}],
                    "max_tokens": 5,
                },
                verify=False,
                timeout=30,
            )

        # Wait for metrics scrape (Limitador ServiceMonitor interval 30s)
        time.sleep(35)

        resp = requests.get(
            f"https://{thanos_host}/api/v1/query",
            params={"query": "authorized_calls"},
            headers={"Authorization": f"Bearer {admin_token}"},
            verify=False,
            timeout=15,
        )
        resp.raise_for_status()
        results = resp.json().get("data", {}).get("result", [])

        users = {
            r["metric"].get("user", "")
            for r in results
            if r["metric"].get("user")
        }
        assert E2E_USER in users, (
            f"Expected '{E2E_USER}' in metric users, got: {users}"
        )
        assert "redhat" in users, (
            f"Expected 'redhat' in metric users, got: {users}"
        )

    def test_user_label_values_endpoint(self, admin_token, thanos_host):
        """Thanos label_values for user returns multiple users."""
        resp = requests.get(
            f"https://{thanos_host}/api/v1/label/user/values",
            params={"match[]": "authorized_calls"},
            headers={"Authorization": f"Bearer {admin_token}"},
            verify=False,
            timeout=15,
        )
        resp.raise_for_status()
        users = resp.json().get("data", [])
        assert len(users) >= 2, (
            f"Expected >= 2 users in label values, got {len(users)}: {users}"
        )
