"""GuideLLM benchmarks tests (merged into evaluation module, see ADR-0007).

Tests split into two groups:
- Template validation (no cluster required, always run)
- Cluster validation (requires oc login + deployed infra)
"""

import subprocess

import pytest
import yaml


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


def _get_benchmarks_docs(extra_args: str = "") -> list:
    output = _helm_template(extra_args)
    docs = list(yaml.safe_load_all(output))
    return [d for d in docs if d and d.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component") == "benchmarks"]


def _get_job(extra_args: str = "") -> dict:
    output = _helm_template(f"--set benchmarks.job.enabled=true {extra_args}")
    docs = list(yaml.safe_load_all(output))
    return next(d for d in docs if d and d["kind"] == "Job" and "benchmarks" in d["metadata"]["name"])


def _get_job_script(extra_args: str = "") -> str:
    job = _get_job(extra_args)
    return job["spec"]["template"]["spec"]["containers"][0]["args"][0]


# --- Template Validation (no cluster needed) ---


class TestBenchmarksHelmTemplate:
    def test_infra_renders_pvc_sa_ca(self):
        docs = _get_benchmarks_docs()
        kinds = {d["kind"] for d in docs}
        assert "PersistentVolumeClaim" in kinds
        assert "ServiceAccount" in kinds
        assert "ConfigMap" in kinds
        assert "Job" not in kinds

    def test_benchmarks_disabled_renders_nothing(self):
        docs = _get_benchmarks_docs("--set benchmarks.enabled=false")
        assert len(docs) == 0

    def test_job_enabled_renders_job(self):
        output = _helm_template("--set benchmarks.job.enabled=true")
        docs = list(yaml.safe_load_all(output))
        job_kinds = [d for d in docs if d and d["kind"] == "Job" and "benchmarks" in d["metadata"]["name"]]
        assert len(job_kinds) == 1

    def test_job_uses_correct_image(self):
        job = _get_job()
        container = job["spec"]["template"]["spec"]["containers"][0]
        assert "guidellm" in container["image"]

    def test_job_mounts_results_pvc(self):
        job = _get_job()
        volumes = job["spec"]["template"]["spec"]["volumes"]
        pvc_names = [
            v["persistentVolumeClaim"]["claimName"]
            for v in volumes
            if "persistentVolumeClaim" in v
        ]
        assert "benchmarks-results" in pvc_names

    def test_job_profile_in_script(self):
        script = _get_job_script("--set benchmarks.benchmark.profile=sweep")
        assert "--rate-type \"sweep\"" in script

    def test_job_name_includes_profile(self):
        job = _get_job("--set benchmarks.benchmark.profile=constant")
        assert "constant" in job["metadata"]["name"]

    def test_auth_token_sets_env_and_backend_kwargs(self):
        job = _get_job("--set benchmarks.benchmark.authToken=test123")
        container = job["spec"]["template"]["spec"]["containers"][0]
        env_names = [e["name"] for e in container.get("env", [])]
        assert "AUTH_TOKEN" in env_names
        script = container["args"][0]
        assert "api_key" in script

    def test_no_auth_has_no_api_key(self):
        job = _get_job()
        container = job["spec"]["template"]["spec"]["containers"][0]
        env_names = [e["name"] for e in container.get("env", [])]
        assert "AUTH_TOKEN" not in env_names
        script = container["args"][0]
        assert "api_key" not in script

    def test_baseline_values_file(self):
        script = _get_job_script(f"-f {CHART_PATH}/values-baseline.yaml")
        assert "svc" in script

    def test_stress_values_file(self):
        script = _get_job_script(f"-f {CHART_PATH}/values-stress.yaml")
        assert "--rate-type \"sweep\"" in script

    def test_processor_in_script(self):
        script = _get_job_script()
        assert "--processor" in script
        assert "TinyLlama" in script

    def test_ca_bundle_mounted(self):
        job = _get_job()
        container = job["spec"]["template"]["spec"]["containers"][0]
        mount_paths = [m["mountPath"] for m in container["volumeMounts"]]
        assert "/etc/pki/tls/certs/ca-bundle.crt" in mount_paths
        env_names = [e["name"] for e in container["env"]]
        assert "SSL_CERT_FILE" in env_names

    def test_ca_bundle_configmap_has_inject_label(self):
        docs = _get_benchmarks_docs()
        cm = next(d for d in docs if d["kind"] == "ConfigMap")
        labels = cm["metadata"]["labels"]
        assert labels.get("config.openshift.io/inject-trusted-cabundle") == "true"

    def test_all_resources_in_evaluation_namespace(self):
        docs = _get_benchmarks_docs()
        for doc in docs:
            assert doc["metadata"]["namespace"] == "evaluation"


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


class TestBenchmarksClusterInfra:
    def test_pvc_exists(self, infra_deployed, oc, evaluation_namespace):
        result = oc(f"get pvc benchmarks-results -n {evaluation_namespace}")
        assert "benchmarks-results" in result

    def test_serviceaccount_exists(self, infra_deployed, oc, evaluation_namespace):
        result = oc(f"get sa benchmarks-runner -n {evaluation_namespace}")
        assert "benchmarks-runner" in result
