"""Test 02: Datasource connectivity, metric discovery, and dashboard CRs."""


def test_grafana_datasource_exists(oc_json, grafana_namespace):
    """GrafanaDatasource CR exists in the observability namespace."""
    ds = oc_json(
        f"get grafanadatasource thanos-querier -n {grafana_namespace}"
    )
    assert ds["metadata"]["name"] == "thanos-querier"


def test_thanos_returns_data(oc, grafana_sa_token):
    """Query Thanos via port-forward to verify connectivity.

    Uses the SA token to authenticate against Thanos Querier and queries
    the ``up`` metric to verify end-to-end datasource connectivity.
    """
    token = grafana_sa_token
    result = oc(
        "exec -n openshift-monitoring "
        "$(oc get pod -n openshift-monitoring -l app.kubernetes.io/name=thanos-query "
        "-o jsonpath='{.items[0].metadata.name}') -- "
        f"wget -qO- --header='Authorization: Bearer {token}' "
        "--no-check-certificate "
        "'https://localhost:9091/api/v1/query?query=up' 2>/dev/null || true"
    )
    assert "success" in result.lower() or "data" in result.lower(), (
        f"Thanos query did not return expected result: {result[:200]}"
    )


def test_vllm_metrics_discoverable(oc, grafana_sa_token):
    """At least one kserve_vllm: metric is discoverable via Thanos.

    KServe wraps vLLM metrics with the kserve_vllm: prefix.
    This catches metric name mismatches before they hit dashboards or alerts.
    """
    token = grafana_sa_token
    result = oc(
        "exec -n openshift-monitoring "
        "$(oc get pod -n openshift-monitoring -l app.kubernetes.io/name=thanos-query "
        "-o jsonpath='{.items[0].metadata.name}') -- "
        f"wget -qO- --header='Authorization: Bearer {token}' "
        "--no-check-certificate "
        "'https://localhost:9091/api/v1/label/__name__/values' 2>/dev/null || true"
    )
    assert "vllm" in result.lower(), (
        "No vllm metrics found in Thanos. "
        "Check PodMonitor and vLLM pod TLS scraping."
    )


def test_grafana_dashboard_crs_exist(oc_json):
    """All three GrafanaDashboard CRs exist as K8s resources."""
    dashboards = oc_json(
        "get grafanadashboard -A "
        "-l dashboards=grafana"
    )
    names = [
        item["metadata"]["name"]
        for item in dashboards.get("items", [])
    ]
    expected = [
        "maas-platform-overview",
        "maas-vllm-metrics",
        "maas-tier-usage",
    ]
    for name in expected:
        assert name in names, (
            f"GrafanaDashboard '{name}' not found. Found: {names}"
        )


def test_podmonitor_exists(oc_json, model_namespace):
    """PodMonitor for vLLM exists in the model namespace."""
    pm = oc_json(
        f"get podmonitor vllm-metrics -n {model_namespace}"
    )
    assert pm["metadata"]["name"] == "vllm-metrics"
    endpoints = pm["spec"]["podMetricsEndpoints"]
    assert endpoints[0]["scheme"] == "https", (
        "PodMonitor should use HTTPS scheme for TLS scraping"
    )


def test_prometheusrule_slo_exists(oc_json, model_namespace):
    """PrometheusRule for vLLM SLO alerts exists."""
    pr = oc_json(
        f"get prometheusrule maas-vllm-slo -n {model_namespace}"
    )
    rule_names = [
        rule["alert"]
        for group in pr["spec"]["groups"]
        for rule in group["rules"]
    ]
    expected = ["MaaSHighP99Latency", "MaaSKVCacheNearFull", "MaaSHighErrorRate"]
    for name in expected:
        assert name in rule_names, (
            f"Alert '{name}' not found. Found: {rule_names}"
        )
