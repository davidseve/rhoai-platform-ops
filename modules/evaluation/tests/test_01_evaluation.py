"""Evaluation module E2E tests.

Tests split into two groups:
- Template validation (no cluster required, always run)
- Cluster validation (requires oc login + deployed evaluation infra)
"""

import subprocess

import pytest
import urllib3
import requests
import yaml

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

CHART_PATH = "modules/evaluation/charts/evaluation"


def _helm_template(extra_args: str = "") -> str:
    result = subprocess.run(
        f"helm template evaluation {CHART_PATH} {extra_args}",
        shell=True,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


def _get_docs(extra_args: str = "") -> list:
    output = _helm_template(extra_args)
    return [d for d in yaml.safe_load_all(output) if d]


# --- Template Validation (no cluster needed) ---


class TestHelmTemplate:
    def test_renders_namespace(self):
        docs = _get_docs()
        kinds = {d["kind"] for d in docs}
        assert "Namespace" in kinds

    def test_renders_evalhub_cr(self):
        docs = _get_docs()
        evalhub = next(
            (d for d in docs if d["kind"] == "EvalHub"), None
        )
        assert evalhub is not None
        assert evalhub["metadata"]["namespace"] == "evaluation"

    def test_renders_mlflow_cr(self):
        docs = _get_docs()
        mlflow = next(
            (d for d in docs if d["kind"] == "MLflow"), None
        )
        assert mlflow is not None
        assert "namespace" not in mlflow["metadata"]

    def test_renders_mlflow_db_secret(self):
        docs = _get_docs()
        secret = next(
            (d for d in docs if d["kind"] == "Secret" and d["metadata"]["name"] == "mlflow-db-config"),
            None,
        )
        assert secret is not None
        assert secret["metadata"]["namespace"] == "redhat-ods-applications"

    def test_mlflow_db_secret_uses_dedicated_database(self):
        docs = _get_docs()
        secret = next(
            d for d in docs if d["kind"] == "Secret" and d["metadata"]["name"] == "mlflow-db-config"
        )
        db_url = secret["stringData"]["db-url"]
        assert "/mlflow?" in db_url, f"Expected dedicated 'mlflow' database in URI, got: {db_url}"

    def test_renders_evalhub_db_secret(self):
        docs = _get_docs()
        secret = next(
            (d for d in docs if d["kind"] == "Secret" and d["metadata"]["name"] == "evalhub-db"),
            None,
        )
        assert secret is not None

    def test_evalhub_db_secret_uses_dedicated_database(self):
        docs = _get_docs()
        secret = next(
            d for d in docs if d["kind"] == "Secret" and d["metadata"]["name"] == "evalhub-db"
        )
        db_url = secret["stringData"]["db-url"]
        assert "/evalhub?" in db_url, f"Expected dedicated 'evalhub' database in URI, got: {db_url}"

    def test_renders_mlflow_route(self):
        docs = _get_docs()
        route = next(
            (d for d in docs if d["kind"] == "Route" and d["metadata"]["name"] == "mlflow"),
            None,
        )
        assert route is not None
        assert route["metadata"]["namespace"] == "redhat-ods-applications"

    def test_evalhub_has_providers(self):
        docs = _get_docs()
        evalhub = next(d for d in docs if d["kind"] == "EvalHub")
        assert len(evalhub["spec"]["providers"]) > 0

    def test_evalhub_has_database_secret(self):
        docs = _get_docs()
        evalhub = next(d for d in docs if d["kind"] == "EvalHub")
        assert evalhub["spec"]["database"]["secret"] == "evalhub-db"

    def test_mlflow_has_backend_store(self):
        docs = _get_docs()
        mlflow = next(d for d in docs if d["kind"] == "MLflow")
        assert mlflow["spec"]["backendStoreUriFrom"]["name"] == "mlflow-db-config"

    def test_evalhub_disabled(self):
        docs = _get_docs("--set evalhub.enabled=false")
        kinds = {d["kind"] for d in docs}
        assert "EvalHub" not in kinds

    def test_mlflow_disabled(self):
        docs = _get_docs("--set mlflow.enabled=false")
        kinds = {d["kind"] for d in docs}
        assert "MLflow" not in kinds

    def test_skip_dry_run_annotations(self):
        docs = _get_docs()
        crd_resources = [d for d in docs if d["kind"] in ("EvalHub", "MLflow", "Route")]
        for r in crd_resources:
            annotations = r["metadata"].get("annotations", {})
            assert annotations.get("argocd.argoproj.io/sync-options") == "SkipDryRunOnMissingResource=true"


# --- Cluster Validation (requires oc login + deployed evaluation infra) ---


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


class TestClusterInfra:
    def test_namespace_exists(self, infra_deployed, oc, evaluation_namespace):
        result = oc(f"get ns {evaluation_namespace}")
        assert evaluation_namespace in result

    def test_evalhub_ready(self, infra_deployed, oc, evaluation_namespace):
        phase = oc(f"get evalhub evalhub -n {evaluation_namespace} -o jsonpath='{{.status.phase}}'")
        assert "Ready" in phase

    def test_evalhub_pod_running(self, infra_deployed, oc, evaluation_namespace):
        result = oc(f"get pods -n {evaluation_namespace} -l app=eval-hub -o jsonpath='{{.items[0].status.phase}}'")
        assert "Running" in result

    def test_mlflow_available(self, infra_deployed, oc):
        status = oc(
            "get mlflow mlflow -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}'"
        )
        assert "True" in status

    def test_mlflow_pod_running(self, infra_deployed, oc):
        result = oc(
            "get pods -n redhat-ods-applications -l app=mlflow -o jsonpath='{.items[0].status.phase}'"
        )
        assert "Running" in result

    def test_evalhub_health_endpoint(self, infra_deployed, oc, evaluation_namespace):
        host = oc(f"get route evalhub -n {evaluation_namespace} -o jsonpath='{{.spec.host}}'")
        resp = requests.get(f"https://{host}/api/v1/health", verify=False, timeout=10)
        assert resp.status_code == 200
        assert resp.json()["status"] == "healthy"

    def test_mlflow_ui_accessible(self, infra_deployed, oc):
        host = oc(
            "get route mlflow -n redhat-ods-applications -o jsonpath='{.spec.host}'"
        )
        resp = requests.get(f"https://{host}/mlflow/", verify=False, timeout=10)
        assert resp.status_code == 200

    def test_mlflow_db_secret_exists(self, infra_deployed, oc):
        result = oc("get secret mlflow-db-config -n redhat-ods-applications -o name")
        assert "mlflow-db-config" in result

    def test_evalhub_db_secret_exists(self, infra_deployed, oc, evaluation_namespace):
        result = oc(f"get secret evalhub-db -n {evaluation_namespace} -o name")
        assert "evalhub-db" in result

    @pytest.mark.parametrize("db_name", ["mlflow", "evalhub", "model_registry"])
    def test_dedicated_database_exists(self, infra_deployed, oc, db_name):
        """Verify dedicated databases exist in the shared PostgreSQL instance."""
        result = oc(
            "exec deploy/maas-db -n redhat-ods-applications -- "
            f"psql -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname = '{db_name}'\""
        )
        assert "1" in result, f"Database '{db_name}' not found in PostgreSQL"
