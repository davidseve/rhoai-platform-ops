"""Test 01: Grafana Operator and instance health."""

import requests


def test_grafana_operator_csv_succeeded(oc):
    """Grafana Operator CSV is in Succeeded phase."""
    phase = oc(
        "get csv -n openshift-operators "
        "-l operators.coreos.com/grafana-operator.openshift-operators "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Succeeded", f"Grafana Operator CSV phase: {phase}"


def test_grafana_pod_running(oc, grafana_namespace, grafana_name):
    """At least one Grafana pod is Running."""
    phase = oc(
        f"get pods -n {grafana_namespace} "
        f"-l app={grafana_name} "
        "-o jsonpath='{.items[0].status.phase}'"
    ).strip("'")
    assert phase == "Running", f"Grafana pod phase: {phase}"


def test_grafana_route_oauth_redirect(grafana_route_url):
    """Grafana Route responds with OAuth redirect (302) for unauthenticated requests."""
    resp = requests.get(
        grafana_route_url,
        verify=False,
        allow_redirects=False,
        timeout=15,
    )
    assert resp.status_code in (302, 403), (
        f"Expected OAuth redirect (302) or forbidden (403), got {resp.status_code}"
    )


def test_grafana_route_rejects_unauthenticated(grafana_route_url):
    """Grafana API is not accessible without authentication."""
    resp = requests.get(
        f"{grafana_route_url}/api/health",
        verify=False,
        allow_redirects=False,
        timeout=15,
    )
    assert resp.status_code != 200, (
        "Grafana API should not be accessible without authentication"
    )
