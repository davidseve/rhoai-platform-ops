"""Governance enforcement: authentication, authorization, and rate limits.

RHOAI 3.4 MaaSSubscription model: rate limits are managed by the
maas-controller via TokenRateLimitPolicy per model.  tinyllama-test has
free-tier limits (5000 tok/1m) and tinyllama-fast (10000 tok/1m).
"""

import os

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

TOKEN_RATE_BURST = int(os.getenv("MAAS_TOKEN_RATE_BURST", "15"))


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


# ---------------------------------------------------------------------------
# Token rate limiting -- per-model
# ---------------------------------------------------------------------------

class TestTokenRateLimiting:
    """tinyllama-test free-tier subscription: 5000 tok/1m.

    Sends sequential requests with max_tokens=500 (~520 tokens each including
    prompt).  ~10 successful responses exhaust the budget.  At least one of
    TOKEN_RATE_BURST requests must return 429.

    RHOAI 3.4 EA2 bug: odh-model-controller AuthPolicy exposes groups in
    auth.identity.user.groups (array), but maas-controller TRLP predicates
    reference auth.identity.groups_str (comma-separated string).  The
    predicates never match, so rate limits don't fire.
    """

    MAX_SEQUENTIAL = 3

    @pytest.mark.xfail(
        reason="EA2: AuthPolicy groups_str may not be populated. "
        "MaaSAuthPolicy should create per-model AuthPolicy that populates it. "
        "If this xpasses, remove the marker.",
        strict=False,
    )
    def test_token_rate_limit_triggers_429(
        self, maas_url, maas_token, inference_path
    ):
        url = f"{maas_url}{inference_path}"
        headers = {
            "Authorization": f"Bearer {maas_token}",
            "Content-Type": "application/json",
        }
        payload = {
            "model": "tinyllama-test",
            "messages": [{"role": "user", "content": "Say hi"}],
            "max_tokens": 50,
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
            f"Expected at least one 429 from token rate limit after "
            f"{len(statuses)} requests with max_tokens=50 "
            f"(free-tier token limit=5000 tok/1m). "
            f"Status distribution: 200={got_200}, 429={got_429}, "
            f"other={len(statuses) - got_200 - got_429}"
        )

    @pytest.mark.xfail(
        reason="EA2: AuthPolicy groups_str may not be populated.",
        strict=False,
    )
    def test_after_token_rate_limit_still_blocked(
        self, maas_url, maas_token, inference_path, chat_payload
    ):
        """After exhausting model1 tokens, the next request should be 429."""
        url = f"{maas_url}{inference_path}"
        headers = {
            "Authorization": f"Bearer {maas_token}",
            "Content-Type": "application/json",
        }
        resp = requests.post(
            url, headers=headers, json=chat_payload,
            verify=False, timeout=30,
        )
        assert resp.status_code == 429, (
            f"Expected 429 (still token-rate-limited), got {resp.status_code}"
        )


class TestTokenRateLimitIsolation:
    """model2 (10000 tok/1m) should not be affected by model1's token exhaustion."""

    def test_model2_tokens_not_exhausted(
        self, maas_url, maas_token, inference_path_model2
    ):
        url = f"{maas_url}{inference_path_model2}"
        headers = {
            "Authorization": f"Bearer {maas_token}",
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
            f"(token limit=10000 tok/1m, not shared with model1). "
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

    def test_authpolicy_has_kubernetes_auth(self, oc_json, gateway_namespace, gateway_name):
        """Verify the gateway AuthPolicy uses KubernetesTokenReview authentication."""
        data = oc_json(f"get authpolicy -n {gateway_namespace}")
        for item in data.get("items", []):
            target = item.get("spec", {}).get("targetRef", {})
            if target.get("name") != gateway_name:
                continue
            auth = item.get("spec", {}).get("rules", {}).get("authentication", {})
            has_k8s_auth = any(
                "kubernetesTokenReview" in provider
                for provider in auth.values()
                if isinstance(provider, dict)
            )
            if has_k8s_auth:
                return
        pytest.fail(
            f"No AuthPolicy targeting '{gateway_name}' with KubernetesTokenReview found"
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

    def test_telemetrypolicy_exists(self, oc, gateway_namespace, has_telemetrypolicy):
        if not has_telemetrypolicy:
            pytest.skip("TelemetryPolicy not deployed")
        out = oc(f"get telemetrypolicy -n {gateway_namespace} --no-headers")
        assert "user-group" in out

    def test_tier_groups_exist(self, oc):
        out = oc("get groups --no-headers")
        assert out.strip(), "No groups found in cluster"
