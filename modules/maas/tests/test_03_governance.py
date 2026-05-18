"""Governance enforcement: authentication, authorization, and rate limits.

RHOAI 3.4 GA: inference requires API keys (sk-oai-*), not OCP tokens.
Rate limits are managed by the maas-controller via TokenRateLimitPolicy
per model. Token budget depends on the subscription tier (free=500,
premium=50000 tok/1m). The API key is tied to the user's subscription.
"""

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


# ---------------------------------------------------------------------------
# Auth enforcement (model-agnostic -- uses model 1 path)
# ---------------------------------------------------------------------------

class TestAuthEnforcement:

    def test_no_auth_header_returns_401(
        self, maas_url, inference_path, chat_payload
    ):
        resp = requests.post(
            f"{maas_url}{inference_path}",
            headers={"Content-Type": "application/json"},
            json=chat_payload,
            verify=False,
            timeout=15,
        )
        assert resp.status_code in (401, 403)

    def test_invalid_bearer_token_returns_401(
        self, maas_url, inference_path, chat_payload
    ):
        resp = requests.post(
            f"{maas_url}{inference_path}",
            headers={
                "Authorization": "Bearer totally-fake-invalid-token",
                "Content-Type": "application/json",
            },
            json=chat_payload,
            verify=False,
            timeout=15,
        )
        assert resp.status_code in (401, 403)

    def test_empty_bearer_token_returns_401(
        self, maas_url, inference_path, chat_payload
    ):
        resp = requests.post(
            f"{maas_url}{inference_path}",
            headers={
                "Authorization": "Bearer ",
                "Content-Type": "application/json",
            },
            json=chat_payload,
            verify=False,
            timeout=15,
        )
        assert resp.status_code in (401, 403)

    def test_malformed_auth_header_returns_401(
        self, maas_url, inference_path, chat_payload
    ):
        resp = requests.post(
            f"{maas_url}{inference_path}",
            headers={
                "Authorization": "NotBearer some-token",
                "Content-Type": "application/json",
            },
            json=chat_payload,
            verify=False,
            timeout=15,
        )
        assert resp.status_code in (401, 403)


class TestAPIKeyEndpointAuth:

    def test_api_key_endpoint_rejects_no_auth(self, maas_url):
        resp = requests.post(
            f"{maas_url}/maas-api/v1/api-keys",
            headers={"Content-Type": "application/json"},
            json={"name": "should-fail", "expiration": "10m"},
            verify=False,
            timeout=15,
        )
        assert resp.status_code in (401, 403)

    def test_api_key_endpoint_rejects_invalid_token(self, maas_url):
        resp = requests.post(
            f"{maas_url}/maas-api/v1/api-keys",
            headers={
                "Authorization": "Bearer invalid-token-xyz",
                "Content-Type": "application/json",
            },
            json={"name": "should-fail", "expiration": "10m"},
            verify=False,
            timeout=15,
        )
        assert resp.status_code in (401, 403)


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

def _fire_one(url, headers, payload):
    try:
        r = requests.post(
            url, headers=headers, json=payload,
            verify=False, timeout=30,
        )
        return r.status_code
    except requests.RequestException:
        return 0


class TestTokenRateLimiting:
    """Free-tier token rate limiting (500 tok/1m).

    Uses a dedicated free-tier API key (subscription in body) to ensure
    the low token budget is exhaustible within a few requests.
    """

    MAX_SEQUENTIAL = 10

    def test_free_tier_rate_limit_triggers_429(
        self, maas_url, maas_free_api_key, inference_path
    ):
        url = f"{maas_url}{inference_path}"
        headers = {
            "Authorization": f"Bearer {maas_free_api_key['key']}",
            "Content-Type": "application/json",
        }
        payload = {
            "model": "tinyllama-test",
            "messages": [{"role": "user", "content": "Write a detailed story"}],
            "max_tokens": 200,
        }
        statuses = []
        for _ in range(self.MAX_SEQUENTIAL):
            code = _fire_one(url, headers, payload)
            statuses.append(code)
            if code == 429:
                break

        got_429 = statuses.count(429)
        got_200 = statuses.count(200)
        assert got_429 > 0, (
            f"Expected 429 from free-tier token rate limit (500 tok/1m) "
            f"after {len(statuses)} requests with max_tokens=200. "
            f"Statuses: 200={got_200}, 429={got_429}, "
            f"other={len(statuses) - got_200 - got_429}"
        )


class TestTokenRateLimitIsolation:
    """model2 should not be affected by model1's token exhaustion."""

    def test_model2_tokens_not_exhausted(
        self, maas_url, maas_api_key, inference_path_model2
    ):
        url = f"{maas_url}{inference_path_model2}"
        headers = {
            "Authorization": f"Bearer {maas_api_key['key']}",
            "Content-Type": "application/json",
        }
        payload = {
            "model": "tinyllama-fast",
            "messages": [{"role": "user", "content": "Hi"}],
            "max_tokens": 20,
        }
        statuses = []
        for _ in range(3):
            code = _fire_one(url, headers, payload)
            statuses.append(code)

        got_200 = statuses.count(200)
        assert got_200 == 3, (
            f"Expected all 3 requests to model2 to succeed "
            f"(separate token budget, not shared with model1). "
            f"Got: {statuses}"
        )


# ---------------------------------------------------------------------------
# Governance K8s resources
# ---------------------------------------------------------------------------

class TestModelReadiness:
    """Smoke tests: verify model K8s resources are healthy before inference."""

    def test_llminferenceservice_is_ready(self, oc, model_namespace, model_name):
        status = oc(
            f"get llminferenceservice {model_name} -n {model_namespace} "
            f"-o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}'"
        ).strip("'")
        assert status == "True", (
            f"LLMInferenceService {model_name} is not Ready (status={status})"
        )

    def test_httproute_accepted(self, oc_json, model_namespace, model_name):
        data = oc_json(
            f"get httproute {model_name}-kserve-route -n {model_namespace}"
        )
        accepted = False
        for parent in data.get("status", {}).get("parents", []):
            for cond in parent.get("conditions", []):
                if cond.get("type") == "Accepted" and cond.get("status") == "True":
                    accepted = True
                    break
        assert accepted, (
            f"HTTPRoute {model_name}-kserve-route not Accepted by any parent"
        )

    def test_authpolicy_has_kubernetes_auth(self, oc_json, model_namespace, model_name):
        """Verify the per-model AuthPolicy uses KubernetesTokenReview.

        RHOAI 3.4 GA: auth moved from Gateway-level to per-model AuthPolicies
        targeting each model's HTTPRoute. Created by MaaSAuthPolicy controller.
        """
        data = oc_json(f"get authpolicy -n {model_namespace}")
        for item in data.get("items", []):
            auth = item.get("spec", {}).get("rules", {}).get("authentication", {})
            has_k8s_auth = any(
                "kubernetesTokenReview" in provider
                for provider in auth.values()
                if isinstance(provider, dict)
            )
            if has_k8s_auth:
                return
        pytest.fail(
            f"No AuthPolicy with KubernetesTokenReview found in {model_namespace}"
        )


class TestGovernanceResources:
    """Verify governance Kubernetes resources exist."""

    def test_authpolicy_exists(self, oc, gateway_namespace, gateway_name):
        out = oc(
            f"get authpolicy -n {gateway_namespace} -o jsonpath="
            f"'{{.items[?(@.spec.targetRef.name==\"{gateway_name}\")].metadata.name}}'"
        )
        assert out.strip("'"), "No AuthPolicy targeting the Gateway found"

    def test_tokenratelimitpolicy_exists(self, oc, model_namespace, model_name):
        out = oc(
            f"get tokenratelimitpolicy -n {model_namespace} --no-headers"
        )
        assert f"maas-trlp-{model_name}" in out, (
            f"Expected maas-controller TokenRateLimitPolicy 'maas-trlp-{model_name}' "
            f"in namespace {model_namespace}. Got: {out}"
        )

    def test_maasauthpolicy_exists(self, oc, model_namespace, model_name):
        """MaaSAuthPolicy exists for each model, enabling API key auth."""
        phase = oc(
            f"get maasauthpolicy {model_name} -n {model_namespace} "
            f"-o jsonpath='{{.status.phase}}'"
        ).strip("'")
        assert phase in ("Active", "Pending"), (
            f"MaaSAuthPolicy '{model_name}' not active. Got: {phase}"
        )

    def test_telemetrypolicy_exists(self, oc, gateway_namespace, has_telemetrypolicy):
        """TelemetryPolicy created by maas-controller when Tenant telemetry is enabled."""
        if not has_telemetrypolicy:
            pytest.skip("TelemetryPolicy not deployed (Tenant telemetry disabled)")
        out = oc(f"get telemetrypolicy -n {gateway_namespace} --no-headers")
        assert "maas-telemetry" in out

    def test_tier_groups_exist(self, oc):
        out = oc("get groups --no-headers")
        assert out.strip(), "No groups found in cluster"
