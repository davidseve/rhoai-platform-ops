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
        output = _helm_template("--set job.enabled=true")
        docs = list(yaml.safe_load_all(output))
        job = next(d for d in docs if d and d["kind"] == "Job")
        container = job["spec"]["template"]["spec"]["containers"][0]
        assert "guidellm" in container["image"]

    def test_job_mounts_results_pvc(self):
        output = _helm_template("--set job.enabled=true")
        docs = list(yaml.safe_load_all(output))
        job = next(d for d in docs if d and d["kind"] == "Job")
        volumes = job["spec"]["template"]["spec"]["volumes"]
        pvc_names = [
            v["persistentVolumeClaim"]["claimName"]
            for v in volumes
            if "persistentVolumeClaim" in v
        ]
        assert "benchmarks-results" in pvc_names

    def test_job_profile_in_args(self):
        output = _helm_template("--set job.enabled=true --set benchmark.profile=sweep")
        docs = list(yaml.safe_load_all(output))
        job = next(d for d in docs if d and d["kind"] == "Job")
        args = job["spec"]["template"]["spec"]["containers"][0]["args"]
        rate_type_idx = args.index("--rate-type")
        assert args[rate_type_idx + 1] == "sweep"

    def test_job_name_includes_profile(self):
        output = _helm_template("--set job.enabled=true --set benchmark.profile=constant")
        docs = list(yaml.safe_load_all(output))
        job = next(d for d in docs if d and d["kind"] == "Job")
        assert "constant" in job["metadata"]["name"]

    def test_auth_token_sets_env_and_header(self):
        output = _helm_template("--set job.enabled=true --set benchmark.authToken=test123")
        docs = list(yaml.safe_load_all(output))
        job = next(d for d in docs if d and d["kind"] == "Job")
        container = job["spec"]["template"]["spec"]["containers"][0]
        env_names = [e["name"] for e in container.get("env", [])]
        assert "AUTH_TOKEN" in env_names
        assert "--extra-headers" in container["args"]

    def test_no_auth_skips_env_and_header(self):
        output = _helm_template("--set job.enabled=true")
        docs = list(yaml.safe_load_all(output))
        job = next(d for d in docs if d and d["kind"] == "Job")
        container = job["spec"]["template"]["spec"]["containers"][0]
        assert container.get("env") is None
        assert "--extra-headers" not in container["args"]

    def test_baseline_values_file(self):
        output = _helm_template(
            f"--set job.enabled=true -f {CHART_PATH}/values-baseline.yaml"
        )
        docs = list(yaml.safe_load_all(output))
        job = next(d for d in docs if d and d["kind"] == "Job")
        args = job["spec"]["template"]["spec"]["containers"][0]["args"]
        target_idx = args.index("--target")
        assert "svc" in args[target_idx + 1]

    def test_stress_values_file(self):
        output = _helm_template(
            f"--set job.enabled=true -f {CHART_PATH}/values-stress.yaml"
        )
        docs = list(yaml.safe_load_all(output))
        job = next(d for d in docs if d and d["kind"] == "Job")
        args = job["spec"]["template"]["spec"]["containers"][0]["args"]
        rate_type_idx = args.index("--rate-type")
        assert args[rate_type_idx + 1] == "sweep"


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
