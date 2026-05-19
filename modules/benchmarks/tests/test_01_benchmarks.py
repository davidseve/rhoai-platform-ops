"""Benchmarks module E2E tests.

Tests split into two groups:
- Template validation (no cluster required, always run)
- Cluster validation (requires oc login + deployed infra)
"""

import subprocess

import pytest
import yaml


CHART_PATH = "modules/benchmarks/charts/benchmarks"


def _helm_template(extra_args: str = "") -> str:
    result = subprocess.run(
        f"helm template benchmarks {CHART_PATH} {extra_args}",
        shell=True,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


def _get_job(extra_args: str = "") -> dict:
    output = _helm_template(f"--set job.enabled=true {extra_args}")
    docs = list(yaml.safe_load_all(output))
    return next(d for d in docs if d and d["kind"] == "Job")


def _get_job_script(extra_args: str = "") -> str:
    job = _get_job(extra_args)
    return job["spec"]["template"]["spec"]["containers"][0]["args"][0]


# --- Template Validation (no cluster needed) ---


class TestHelmTemplate:
    def test_infra_only_renders_namespace_pvc_sa(self):
        output = _helm_template()
        docs = list(yaml.safe_load_all(output))
        kinds = {d["kind"] for d in docs if d}
        assert "Namespace" in kinds
        assert "PersistentVolumeClaim" in kinds
        assert "ServiceAccount" in kinds
        assert "Job" not in kinds

    def test_job_enabled_renders_job(self):
        output = _helm_template("--set job.enabled=true")
        docs = list(yaml.safe_load_all(output))
        kinds = {d["kind"] for d in docs if d}
        assert "Job" in kinds

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
        script = _get_job_script("--set benchmark.profile=sweep")
        assert "--rate-type \"sweep\"" in script

    def test_job_name_includes_profile(self):
        job = _get_job("--set benchmark.profile=constant")
        assert "constant" in job["metadata"]["name"]

    def test_auth_token_sets_env_and_backend_kwargs(self):
        job = _get_job("--set benchmark.authToken=test123")
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
        output = _helm_template()
        docs = list(yaml.safe_load_all(output))
        cm = next(d for d in docs if d and d["kind"] == "ConfigMap")
        labels = cm["metadata"]["labels"]
        assert labels.get("config.openshift.io/inject-trusted-cabundle") == "true"


# --- Cluster Validation (requires oc login + deployed benchmarks infra) ---


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
        "oc get ns benchmarks",
        shell=True, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        pytest.skip("Benchmarks namespace not found -- infra not deployed")


class TestClusterInfra:
    def test_namespace_exists(self, infra_deployed, oc, benchmark_namespace):
        result = oc(f"get ns {benchmark_namespace}")
        assert benchmark_namespace in result

    def test_pvc_exists(self, infra_deployed, oc, benchmark_namespace):
        result = oc(f"get pvc benchmarks-results -n {benchmark_namespace}")
        assert "benchmarks-results" in result

    def test_serviceaccount_exists(self, infra_deployed, oc, benchmark_namespace):
        result = oc(f"get sa benchmarks-runner -n {benchmark_namespace}")
        assert "benchmarks-runner" in result
