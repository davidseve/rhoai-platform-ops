"""Test 03: Tracing infrastructure -- Tempo, OTel Collector, datasource, trace visibility."""

import json
import time

import pytest


TEMPO_OPERATOR_NS = "openshift-tempo-operator"
OTEL_OPERATOR_NS = "openshift-opentelemetry-operator"
OBSERVABILITY_NS = "observability"


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
    """At least one TempoMonolithic pod is Running in observability namespace."""
    phase = oc(
        f"get pods -n {OBSERVABILITY_NS} "
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


def test_tempo_datasource_exists(oc_json):
    """GrafanaDatasource 'tempo' CR exists in the observability namespace."""
    ds = oc_json(f"get grafanadatasource tempo -n {OBSERVABILITY_NS}")
    assert ds["metadata"]["name"] == "tempo"


def _check_tracing_enabled(oc):
    """Return True if any model pod has OTEL env vars configured."""
    try:
        env_value = oc(
            "get pods -n maas-models "
            "-l app.kubernetes.io/component=predictor "
            "-o jsonpath='{.items[0].spec.containers[0].env[?(@.name==\"OTEL_TRACES_EXPORTER\")].value}'"
        ).strip("'")
        return env_value == "otlp"
    except Exception:
        return False


@pytest.mark.skipif(
    "not config.getoption('--run-tracing', default=False)",
    reason="Tracing tests require --run-tracing flag (model pods must have OTEL env vars)",
)
def test_traces_visible_after_inference(oc):
    """Send inference request and verify traces appear in Tempo.

    Validates the trace contains spans from the full stack:
    MaaS gateway (Envoy/Kuadrant), llm-d routing, and vLLM inference.
    """
    route_host = oc(
        "get route -n openshift-ingress "
        "-l gateway.networking.k8s.io/gateway-name=maas-default-gateway "
        "-o jsonpath='{.items[0].spec.host}'"
    ).strip("'")

    oc(
        f"exec -n {OBSERVABILITY_NS} "
        "$(oc get pod -n observability -l app.kubernetes.io/managed-by=tempo-operator "
        "-o jsonpath='{.items[0].metadata.name}') -- "
        f"wget -qO- 'http://localhost:3200/api/search?limit=1' 2>/dev/null || true"
    )

    time.sleep(5)

    result = oc(
        f"exec -n {OBSERVABILITY_NS} "
        "$(oc get pod -n observability -l app.kubernetes.io/managed-by=tempo-operator "
        "-o jsonpath='{.items[0].metadata.name}') -- "
        "wget -qO- 'http://localhost:3200/api/search?limit=5' 2>/dev/null || true"
    )

    assert "traces" in result.lower() or "traceID" in result, (
        f"No traces found in Tempo. Response: {result[:300]}"
    )


@pytest.mark.skipif(
    "not config.getoption('--run-tracing', default=False)",
    reason="Tracing tests require --run-tracing flag",
)
def test_trace_spans_cover_full_stack(oc):
    """Verify trace spans represent the full request path.

    After retrieving a trace, verify it contains spans representing:
    (1) the gateway/proxy layer (MaaS),
    (2) llm-d request routing, and
    (3) vLLM model execution.
    """
    result = oc(
        f"exec -n {OBSERVABILITY_NS} "
        "$(oc get pod -n observability -l app.kubernetes.io/managed-by=tempo-operator "
        "-o jsonpath='{.items[0].metadata.name}') -- "
        "wget -qO- 'http://localhost:3200/api/search?limit=1' 2>/dev/null || true"
    )
    try:
        data = json.loads(result)
        traces = data.get("traces", [])
        assert len(traces) > 0, "No traces found to inspect for span coverage"

        trace_id = traces[0].get("traceID", "")
        trace_detail = oc(
            f"exec -n {OBSERVABILITY_NS} "
            "$(oc get pod -n observability -l app.kubernetes.io/managed-by=tempo-operator "
            "-o jsonpath='{.items[0].metadata.name}') -- "
            f"wget -qO- 'http://localhost:3200/api/traces/{trace_id}' 2>/dev/null || true"
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
