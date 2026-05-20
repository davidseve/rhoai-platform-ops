"""Model Registry E2E tests.

Tests split into two groups:
- Template validation (no cluster required, always run)
- Cluster validation (requires oc login + deployed model registry)
"""

import subprocess

import pytest
import yaml

CHART_PATH = "modules/maas/charts/model-registry"
REGISTRY_NAMESPACE = "rhoai-model-registries"
REGISTRY_NAME = "maas-model-registry"


def _helm_template(extra_args: str = "") -> str:
    result = subprocess.run(
        f"helm template model-registry {CHART_PATH} {extra_args}",
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
    def test_renders_model_registry_cr(self):
        docs = _get_docs()
        mr = next((d for d in docs if d["kind"] == "ModelRegistry"), None)
        assert mr is not None
        assert mr["metadata"]["namespace"] == REGISTRY_NAMESPACE
        assert mr["metadata"]["name"] == REGISTRY_NAME

    def test_model_registry_uses_postgres(self):
        docs = _get_docs()
        mr = next(d for d in docs if d["kind"] == "ModelRegistry")
        assert "postgres" in mr["spec"]
        assert mr["spec"]["postgres"]["host"] == "maas-db.redhat-ods-applications.svc"
        assert mr["spec"]["postgres"]["port"] == 5432
        assert mr["spec"]["postgres"]["database"] == "model_registry"

    def test_model_registry_skip_db_creation(self):
        docs = _get_docs()
        mr = next(d for d in docs if d["kind"] == "ModelRegistry")
        assert mr["spec"]["postgres"]["skipDBCreation"] is True

    def test_model_registry_password_secret_ref(self):
        docs = _get_docs()
        mr = next(d for d in docs if d["kind"] == "ModelRegistry")
        ps = mr["spec"]["postgres"]["passwordSecret"]
        assert ps["name"] == "model-registry-db"
        assert ps["key"] == "database-password"

    def test_renders_db_secret(self):
        docs = _get_docs()
        secret = next(
            (d for d in docs if d["kind"] == "Secret" and d["metadata"]["name"] == "model-registry-db"),
            None,
        )
        assert secret is not None
        assert secret["metadata"]["namespace"] == REGISTRY_NAMESPACE

    def test_rest_and_grpc_ports(self):
        docs = _get_docs()
        mr = next(d for d in docs if d["kind"] == "ModelRegistry")
        assert mr["spec"]["rest"]["port"] == 8080
        assert mr["spec"]["grpc"]["port"] == 9090

    def test_service_route_disabled(self):
        docs = _get_docs()
        mr = next(d for d in docs if d["kind"] == "ModelRegistry")
        assert mr["spec"]["rest"]["serviceRoute"] == "disabled"

    def test_skip_dry_run_annotations(self):
        docs = _get_docs()
        for r in docs:
            annotations = r["metadata"].get("annotations", {})
            assert annotations.get("argocd.argoproj.io/sync-options") == "SkipDryRunOnMissingResource=true", \
                f"{r['kind']}/{r['metadata']['name']} missing ArgoCD annotation"


# --- Cluster Validation (requires oc login + deployed model registry) ---


class TestClusterInfra:
    @pytest.fixture(scope="class", autouse=True)
    def skip_if_not_deployed(self):
        result = subprocess.run(
            f"oc get ns {REGISTRY_NAMESPACE}",
            shell=True, capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            pytest.skip("Model registry namespace not found — not deployed")

    def test_namespace_exists(self, oc):
        result = oc(f"get ns {REGISTRY_NAMESPACE}")
        assert REGISTRY_NAMESPACE in result

    def test_model_registry_exists(self, oc):
        result = oc(f"get modelregistries.modelregistry.opendatahub.io {REGISTRY_NAME} -n {REGISTRY_NAMESPACE} -o name")
        assert REGISTRY_NAME in result

    def test_model_registry_pod_running(self, oc):
        result = oc(
            f"get pods -n {REGISTRY_NAMESPACE} -l app={REGISTRY_NAME} "
            f"-o jsonpath='{{.items[0].status.phase}}'"
        )
        assert "Running" in result

    def test_db_secret_exists(self, oc):
        result = oc(f"get secret model-registry-db -n {REGISTRY_NAMESPACE} -o name")
        assert "model-registry-db" in result
