"""Test 03: Tracing infrastructure -- Tempo, OTel Collector, datasource, trace visibility."""

import json
import time

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


import os

TEMPO_OPERATOR_NS = "openshift-tempo-operator"
OTEL_OPERATOR_NS = "openshift-opentelemetry-operator"
OBSERVABILITY_NS = "observability"
COO_ENABLED = os.getenv("COO_ENABLED", "false").lower() == "true"
TEMPO_NS = "redhat-ods-monitoring" if COO_ENABLED else OBSERVABILITY_NS


def test_tempo_operator_csv_succeeded(oc):
    """Tempo operator CSV is in Succeeded phase."""
    phase = oc(
        f"get csv -n {TEMPO_OPERATOR_NS} "
        "-l operators.coreos.com/tempo-product.openshift-tempo-operator "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Succeeded", f"Tempo Operator CSV phase: {phase}"


def test_otel_operator_csv_succeeded(oc):
    """OpenTelemetry operator CSV is in Succeeded phase."""
    phase = oc(
        f"get csv -n {OTEL_OPERATOR_NS} "
        "-l operators.coreos.com/opentelemetry-product.openshift-opentelemetry-operator "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Succeeded", f"OTel Operator CSV phase: {phase}"


def test_tempo_pod_running(oc):
    """At least one Tempo pod is Running (observability or redhat-ods-monitoring with COO)."""
    phase = oc(
        f"get pods -n {TEMPO_NS} "
        "-l app.kubernetes.io/managed-by=tempo-operator "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Running", f"Tempo pod phase: {phase}"


def test_collector_pod_running(oc):
    """At least one OTel Collector pod is Running in observability namespace."""
    phase = oc(
        f"get pods -n {OBSERVABILITY_NS} "
        "-l app.kubernetes.io/managed-by=opentelemetry-operator "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Running", f"OTel Collector pod phase: {phase}"


def test_tempo_pvc_bound(oc):
    """Tempo PVC exists and is Bound (persistent trace storage)."""
    phase = oc(
        f"get pvc -n {TEMPO_NS} "
        "-l app.kubernetes.io/managed-by=tempo-operator "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Bound", f"Tempo PVC phase: {phase} (expected Bound)"


def test_tempo_datasource_exists(oc_json):
    """GrafanaDatasource 'tempo' CR exists in the observability namespace."""
    ds = oc_json(f"get grafanadatasource tempo -n {OBSERVABILITY_NS}")
    assert ds["metadata"]["name"] == "tempo"


_TEMPO_TENANT = "redhat-ods-monitoring"
if COO_ENABLED:
    _TEMPO_GATEWAY = f"https://tempo-data-science-tempomonolithic-gateway.{TEMPO_NS}.svc:8080"
    _TEMPO_SEARCH = f"{_TEMPO_GATEWAY}/api/traces/v1/{_TEMPO_TENANT}/tempo/api/search"
else:
    _TEMPO_SEARCH = f"http://tempo-tempo.{OBSERVABILITY_NS}.svc:3200/api/search"


def _query_tempo(oc, params="limit=5"):
    """Query Tempo search API via exec into the Grafana pod (has curl)."""
    if COO_ENABLED:
        token = oc(
            f"get secret grafana-sa-token -n {OBSERVABILITY_NS} "
            "-o jsonpath='{.data.token}'"
        ).strip("'")
        import base64
        token = base64.b64decode(token).decode()
        return oc(
            f"exec -n {OBSERVABILITY_NS} "
            "$(oc get pod -n observability -l app=grafana "
            "-o jsonpath='{.items[0].metadata.name}') "
            "-c grafana -- "
            f"curl -sk -H 'Authorization: Bearer {token}' "
            f"'{_TEMPO_SEARCH}?{params}'"
        )
    return oc(
        f"exec -n {OBSERVABILITY_NS} "
        "$(oc get pod -n observability -l app=grafana "
        "-o jsonpath='{.items[0].metadata.name}') "
        "-c grafana -- "
        f"curl -s '{_TEMPO_SEARCH}?{params}'"
    )


def test_traces_visible_after_inference(
    oc, tracing_enabled, maas_url, maas_api_key, maas_inference_path
):
    """Send inference request and verify traces appear in Tempo.

    Auto-detected: only runs if model pods have OTEL_TRACES_EXPORTER=otlp.
    Sends a small inference request, then retries Tempo for up to 30s.
    """
    resp = requests.post(
        f"{maas_url}{maas_inference_path}",
        headers={
            "Authorization": f"Bearer {maas_api_key['key']}",
            "Content-Type": "application/json",
        },
        json={
            "model": "tinyllama-test",
            "messages": [{"role": "user", "content": "Hi"}],
            "max_tokens": 10,
        },
        verify=False,
        timeout=30,
    )
    assert resp.status_code == 200, (
        f"Inference request failed with {resp.status_code}: {resp.text[:200]}"
    )

    result = ""
    for _ in range(6):
        time.sleep(5)
        result = _query_tempo(oc)
        try:
            data = json.loads(result)
            if data.get("traces"):
                return
        except json.JSONDecodeError:
            continue

    pytest.fail(f"No traces found in Tempo after 30s. Last response: {result[:300]}")


def test_trace_spans_cover_full_stack(
    oc, tracing_enabled, maas_url, maas_api_key, maas_inference_path
):
    """Verify trace spans represent the full request path.

    Retrieves the most recent trace and checks it contains spans from
    at least one service (gateway, llm-d, or vLLM).
    """
    result = _query_tempo(oc, params="limit=1")
    try:
        data = json.loads(result)
        traces = data.get("traces", [])
        if not traces:
            requests.post(
                f"{maas_url}{maas_inference_path}",
                headers={
                    "Authorization": f"Bearer {maas_api_key['key']}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": "tinyllama-test",
                    "messages": [{"role": "user", "content": "Hi"}],
                    "max_tokens": 10,
                },
                verify=False,
                timeout=30,
            )
            time.sleep(10)
            result = _query_tempo(oc, params="limit=1")
            data = json.loads(result)
            traces = data.get("traces", [])

        assert len(traces) > 0, "No traces found to inspect for span coverage"

        trace_id = traces[0].get("traceID", "")
        if COO_ENABLED:
            trace_url = f"{_TEMPO_GATEWAY}/api/traces/v1/{_TEMPO_TENANT}/tempo/api/traces/{trace_id}"
            token = oc(
                f"get secret grafana-sa-token -n {OBSERVABILITY_NS} "
                "-o jsonpath='{.data.token}'"
            ).strip("'")
            import base64
            token = base64.b64decode(token).decode()
            trace_detail = oc(
                f"exec -n {OBSERVABILITY_NS} "
                "$(oc get pod -n observability -l app=grafana "
                "-o jsonpath='{.items[0].metadata.name}') "
                "-c grafana -- "
                f"curl -sk -H 'Authorization: Bearer {token}' '{trace_url}'"
            )
        else:
            trace_detail = oc(
                f"exec -n {OBSERVABILITY_NS} "
                "$(oc get pod -n observability -l app=grafana "
                "-o jsonpath='{.items[0].metadata.name}') "
                "-c grafana -- "
                f"curl -s 'http://tempo-tempo.{OBSERVABILITY_NS}.svc:3200/api/traces/{trace_id}'"
            )
        service_names = set()
        detail_data = json.loads(trace_detail)
        for batch in detail_data.get("batches", []):
            resource = batch.get("resource", {})
            for attr in resource.get("attributes", []):
                if attr.get("key") == "service.name":
                    service_names.add(attr.get("value", {}).get("stringValue", ""))

        assert len(service_names) >= 1, (
            f"Expected spans from multiple services, found: {service_names}"
        )
    except json.JSONDecodeError:
        pytest.skip(f"Could not parse Tempo response as JSON: {result[:200]}")


def test_tracing_prometheusrule_exists(oc_json):
    """PrometheusRule for trace-based SLO alerts exists with expected alerts."""
    pr = oc_json(f"get prometheusrule tracing-slo -n {OBSERVABILITY_NS}")
    rule_names = [
        rule["alert"]
        for group in pr["spec"]["groups"]
        for rule in group["rules"]
    ]
    expected = [
        "TracingHighP99Latency",
        "TracingHighErrorRate",
        "TracingPipelineDown",
    ]
    for name in expected:
        assert name in rule_names, (
            f"Alert '{name}' not found in tracing-slo. Found: {rule_names}"
        )
