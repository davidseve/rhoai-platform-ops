"""EvalHub API and infrastructure readiness tests.

Validates that EvalHub is properly configured and ready to accept evaluations.
No actual evaluations are launched — these tests verify infra only.
"""

import base64
import json
import subprocess

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


@pytest.fixture(scope="module")
def cluster_available():
    result = subprocess.run(
        "oc whoami", shell=True, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        pytest.skip("Not logged into cluster (oc whoami failed)")


@pytest.fixture(scope="module")
def infra_deployed(cluster_available):
    result = subprocess.run(
        "oc get ns evaluation",
        shell=True, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        pytest.skip("Evaluation namespace not found -- infra not deployed")


class TestEvalHubAPI:
    def test_evalhub_providers_registered(self, infra_deployed, evalhub_url, oc_token):
        resp = requests.get(
            f"{evalhub_url}/api/v1/evaluations/providers",
            headers={"Authorization": f"Bearer {oc_token}", "X-Tenant": "evaluation"},
            verify=False,
            timeout=10,
        )
        assert resp.status_code == 200
        providers = resp.json()["items"]
        provider_ids = [p["resource"]["id"] for p in providers]
        assert len(provider_ids) >= 4
        for expected in ["lm_evaluation_harness", "guidellm", "garak", "lighteval"]:
            assert expected in provider_ids

    def test_evalhub_lm_eval_benchmarks(self, infra_deployed, evalhub_url, oc_token):
        resp = requests.get(
            f"{evalhub_url}/api/v1/evaluations/providers?benchmarks=true",
            headers={"Authorization": f"Bearer {oc_token}", "X-Tenant": "evaluation"},
            verify=False,
            timeout=10,
        )
        providers = resp.json()["items"]
        lm_eval = next(p for p in providers if p["resource"]["id"] == "lm_evaluation_harness")
        assert len(lm_eval["benchmarks"]) > 100

    def test_evalhub_guidellm_benchmarks(self, infra_deployed, evalhub_url, oc_token):
        resp = requests.get(
            f"{evalhub_url}/api/v1/evaluations/providers?benchmarks=true",
            headers={"Authorization": f"Bearer {oc_token}", "X-Tenant": "evaluation"},
            verify=False,
            timeout=10,
        )
        providers = resp.json()["items"]
        guidellm = next(p for p in providers if p["resource"]["id"] == "guidellm")
        benchmark_ids = [b["id"] for b in guidellm["benchmarks"]]
        assert "throughput" in benchmark_ids
        assert "sweep" in benchmark_ids

    def test_evalhub_collections_available(self, infra_deployed, evalhub_url, oc_token):
        resp = requests.get(
            f"{evalhub_url}/api/v1/evaluations/collections",
            headers={"Authorization": f"Bearer {oc_token}", "X-Tenant": "evaluation"},
            verify=False,
            timeout=10,
        )
        assert resp.status_code == 200
        collections = resp.json()["items"]
        collection_ids = [c["resource"]["id"] for c in collections]
        assert "leaderboard-v2" in collection_ids

    def test_model_auth_secret_exists(self, infra_deployed, oc):
        result = oc("get secret model-auth -n evaluation -o name")
        assert "model-auth" in result

    def test_model_auth_has_valid_ca(self, infra_deployed, oc):
        b64 = oc("get secret model-auth -n evaluation -o jsonpath='{.data.ca_cert}'")
        ca_pem = base64.b64decode(b64).decode()
        assert ca_pem.startswith("-----BEGIN CERTIFICATE-----")

    def test_evalhub_api_accepts_auth(self, infra_deployed, evalhub_url, oc_token):
        resp = requests.get(
            f"{evalhub_url}/api/v1/evaluations/jobs",
            headers={"Authorization": f"Bearer {oc_token}", "X-Tenant": "evaluation"},
            verify=False,
            timeout=10,
        )
        assert resp.status_code == 200

    def test_mlflow_workspace_accessible(self, infra_deployed, mlflow_url, oc_token):
        resp = requests.post(
            f"{mlflow_url}/api/2.0/mlflow/experiments/search",
            headers={
                "Authorization": f"Bearer {oc_token}",
                "X-Mlflow-Workspace": "evaluation",
                "Content-Type": "application/json",
            },
            json={"max_results": 1},
            verify=False,
            timeout=10,
        )
        assert resp.status_code == 200
