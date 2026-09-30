"""Test 04: Cluster Observability Operator (COO) stack health.

Validates that COO is installed and the RHOAI-managed observability stack
(Prometheus, Alertmanager, Tempo, OTel Collector, Thanos) is running in
redhat-ods-monitoring.
"""

import pytest


COO_NAMESPACE = "openshift-operators"
MONITORING_NS = "redhat-ods-monitoring"


def test_coo_csv_succeeded(oc):
    """Cluster Observability Operator CSV is in Succeeded phase."""
    phase = oc(
        f"get csv -n {COO_NAMESPACE} "
        "-l operators.coreos.com/cluster-observability-operator.openshift-operators "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Succeeded", f"COO CSV phase: {phase}"


def test_monitoring_namespace_exists(oc):
    """redhat-ods-monitoring namespace exists."""
    phase = oc(
        f"get namespace {MONITORING_NS} "
        "-o jsonpath='{.status.phase}'"
    ).strip("'")
    assert phase == "Active", f"Namespace phase: {phase}"


def test_prometheus_pod_running(oc):
    """Prometheus pod is Running in redhat-ods-monitoring."""
    phase = oc(
        f"get pods -n {MONITORING_NS} "
        "-l app.kubernetes.io/name=prometheus "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Running", f"Prometheus pod phase: {phase}"


def test_alertmanager_pod_running(oc):
    """Alertmanager pod is Running in redhat-ods-monitoring."""
    phase = oc(
        f"get pods -n {MONITORING_NS} "
        "-l app.kubernetes.io/name=alertmanager "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Running", f"Alertmanager pod phase: {phase}"


def test_thanos_querier_pod_running(oc):
    """Thanos Querier pod is Running in redhat-ods-monitoring."""
    phase = oc(
        f"get pods -n {MONITORING_NS} "
        "-l app.kubernetes.io/part-of=ThanosQuerier "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Running", f"Thanos Querier pod phase: {phase}"


def test_rhoai_collector_pod_running(oc):
    """RHOAI OTel Collector pod is Running in redhat-ods-monitoring."""
    phase = oc(
        f"get pods -n {MONITORING_NS} "
        "-l app.kubernetes.io/managed-by=opentelemetry-operator "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Running", f"RHOAI OTel Collector pod phase: {phase}"


def test_rhoai_tempo_pod_running(oc):
    """RHOAI Tempo pod is Running in redhat-ods-monitoring."""
    phase = oc(
        f"get pods -n {MONITORING_NS} "
        "-l app.kubernetes.io/managed-by=tempo-operator "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Running", f"RHOAI Tempo pod phase: {phase}"


def test_uiplugin_monitoring_exists(oc_json):
    """UIPlugin 'monitoring' CR exists."""
    plugin = oc_json("get uiplugin monitoring")
    assert plugin["metadata"]["name"] == "monitoring"
    assert plugin["spec"]["type"] == "Monitoring"


def test_uiplugin_troubleshooting_exists(oc_json):
    """UIPlugin 'troubleshooting-panel' CR exists."""
    plugin = oc_json("get uiplugin troubleshooting-panel")
    assert plugin["metadata"]["name"] == "troubleshooting-panel"
    assert plugin["spec"]["type"] == "TroubleshootingPanel"


def test_uiplugin_tracing_exists(oc_json):
    """UIPlugin 'distributed-tracing' CR exists."""
    plugin = oc_json("get uiplugin distributed-tracing")
    assert plugin["metadata"]["name"] == "distributed-tracing"
    assert plugin["spec"]["type"] == "DistributedTracing"


def test_observability_dashboard_enabled(oc):
    """OdhDashboardConfig has observabilityDashboard: true."""
    value = oc(
        "get odhdashboardconfig odh-dashboard-config "
        "-n redhat-ods-applications "
        "-o jsonpath='{.spec.dashboardConfig.observabilityDashboard}'"
    ).strip("'")
    assert value == "true", (
        f"observabilityDashboard is '{value}', expected 'true'"
    )
