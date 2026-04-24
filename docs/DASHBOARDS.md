# Dashboards and Trace Exploration

How to access Grafana, understand each dashboard, explore distributed traces, and generate traffic to populate everything.

## Accessing Grafana

Grafana is protected by an OpenShift OAuth proxy. Only authenticated cluster users can access it.

```bash
# Get the Grafana URL
oc get route grafana-route -n observability -o jsonpath='https://{.spec.host}'
```

1. Open the URL in a browser
2. Click **Log in with OpenShift**
3. Authenticate with your cluster credentials
4. You will be redirected to the Grafana home page

The OAuth proxy enforces that the user has `get` permission on the Grafana Route in the `observability` namespace.

## Generating Traffic

Dashboards need real inference traffic to show meaningful data. Use the built-in traffic generator:

```bash
# Default: 50 requests, 2 workers, 1s delay, both models
make generate-traffic

# Heavy load: 200 requests, 4 concurrent, 0.5s delay
REQUESTS=200 CONCURRENCY=4 DELAY=0.5 make generate-traffic

# Single model only
MODELS=tinyllama-test make generate-traffic
```

The script automatically discovers the cluster domain, obtains a MaaS token, and sends varied prompts (short and long) to both models in round-robin. For each request, it also emits an OTLP trace span to the collector (via port-forward) representing the gateway-to-model flow. Wait 1-2 minutes after completion for metrics to propagate through the Prometheus scrape cycle; traces appear in Tempo within seconds.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REQUESTS` | 50 | Total number of inference requests |
| `CONCURRENCY` | 2 | Parallel workers sending requests (keep <=2, see [Gateway 5xx Errors](#gateway-5xx-errors)) |
| `DELAY` | 1 | Seconds between requests per worker |
| `MODELS` | `tinyllama-test,tinyllama-fast` | Comma-separated model names |
| `MAX_TOKENS` | 30 | Max tokens per completion request |
| `EMIT_TRACES` | `true` | Send OTLP traces to collector for each request |

## Dashboard Inventory

Four dashboards are deployed. Three live in the MaaS module (gated by `grafana.enabled`), one in the observability module (gated by `tempo.enabled`).

### 1. MaaS Platform Overview

**Location**: Dashboards > MaaS Platform Overview

Provides a high-level view of the API gateway traffic -- how many requests are flowing, how many are being rejected, and which models/users are active.

| Panel | What it shows | What to look for |
|-------|---------------|------------------|
| Authorized Requests/sec | Successful requests passing through Kuadrant | Should show ~2 req/s during traffic generation |
| Limited Requests/sec | Requests rejected by rate limits | Non-zero after sustained traffic exceeds limits |
| Gateway Errors/sec | WASM auth timeout errors (Kuadrant) | Should be 0; non-zero means auth evaluation exceeded the 200ms WASM timeout |
| Rejection Ratio | Percentage of requests being rate-limited | Spikes indicate rate limit policies are active |
| Total Requests (5m) | Sum of authorized + limited requests over 5m window | Overall traffic volume |
| Authorized vs Limited vs 5xx Over Time | Time series of accepted, rejected, and 5xx errors | Visualizes rate limit behavior and error spikes |
| Rejection Ratio Over Time | Time series of rejection percentage | Correlates with bursts of traffic |
| Calls by Model | Per-model breakdown of requests | Both models should appear with similar volumes |
| Calls by User | Per-user breakdown (hash suffix stripped) | Shows which users are generating traffic |

### 2. vLLM Inference Metrics

**Location**: Dashboards > vLLM Inference Metrics

Deep dive into model serving performance -- latency, throughput, and resource utilization at the vLLM engine level.

| Panel | What it shows | What to look for |
|-------|---------------|------------------|
| Generation Token Throughput (TPS) | Output tokens produced per second | Non-zero during and shortly after traffic |
| Prompt Token Throughput (TPS) | Input tokens processed per second | Varies with prompt length (short vs long) |
| Scheduler State | Running, waiting, and swapped request counts | `running` should be non-zero during load |
| KV Cache Utilization | Percentage of GPU/CPU KV cache in use | Non-zero means the model is actively serving |
| Processed Requests by Finish Reason | Breakdown of completed vs stopped requests | Most should show `stop` (normal completion) |
| Request Prompt Length Distribution | Histogram of input prompt lengths | Should show varied lengths from the generator |
| E2E Request Latency | End-to-end latency percentiles (P50/P90/P99) | Shows model serving performance |
| TTFT (Time To First Token) | Latency until first token is generated | Key metric for interactive responsiveness |
| TPOT (Time Per Output Token) | Latency per generated token | Shows decoding efficiency |

### 3. MaaS Per-Tier Usage

**Location**: Dashboards > MaaS Per-Tier Usage

Compares resource consumption between free and premium tiers -- useful for capacity planning and validating rate limit policies.

| Panel | What it shows | What to look for |
|-------|---------------|------------------|
| Free Tier Requests/sec | Request rate for the free tier | Traffic volume for the default tier |
| Premium Tier Requests/sec | Request rate for the premium tier | Traffic from premium-tier users |
| Free Tier Rate Limited/sec | Rate-limited requests for free tier | Shows if free tier is hitting limits |
| Premium Tier Rate Limited/sec | Rate-limited requests for premium tier | Premium should have higher limits |
| Authorized/Limited Calls by Tier | Stacked comparison of tiers | Visualizes tier policy differences |
| Token Usage by Tier (vLLM) | Token consumption split by tier | Tracks actual resource consumption |
| Calls by Tier and Model | Cross-reference tier and model | Shows which tier uses which model most |

### 4. Trace Exploration

**Location**: Dashboards > Trace Exploration

Visualizes distributed traces collected by the OpenTelemetry Collector and stored in Tempo. The traffic generator emits OTLP traces for each inference request, producing two spans per trace: a `maas-gateway` span (representing the gateway hop) and a `vllm-<model>` span (representing model inference). When a vLLM image with native OTEL support is available, real model-level traces will replace the synthetic ones.

| Panel | What it shows | What to look for |
|-------|---------------|------------------|
| Service Map | Graph of services and their connections | Shows `maas-gateway` -> `vllm-<model>` request flow |
| Latency Distribution (from spanmetrics) | Histogram of request latencies from spans | Derived from traces, reflects actual inference times |
| Recent Traces | Table of most recent traces with service and duration | Click a trace ID to drill into the gateway + inference spans |
| Request Rate by Service (from spanmetrics) | Per-service request throughput from spans | Shows traffic split between `maas-gateway` and each model |

**Note**: Until vLLM images include native OTEL packages (see [ROADMAP](ROADMAP.md)), the traffic generator produces the traces. Set `EMIT_TRACES=false` to disable trace emission.

## Exploring Traces in Grafana

Beyond the dashboard, Grafana's **Explore** view provides interactive trace search and drill-down via the Tempo datasource.

### Search for traces

1. In Grafana, click the compass icon (**Explore**) in the left sidebar
2. Select **Tempo** as the datasource (top-left dropdown)
3. Use the **Search** tab to filter traces:
   - **Service Name**: filter by `maas-gateway`, `vllm-tinyllama-test`, etc.
   - **Span Name**: filter by operation
   - **Duration**: find slow requests (e.g., `> 5s`)
   - **Tags**: filter by custom attributes
4. Click a trace to see its full span tree

### Read a trace waterfall

Each trace shows:
- **Root span** (`maas-gateway`): the API gateway entry point with `http.route`, `http.status_code`, and `model.name`
- **Child span** (`vllm-<model>`): the inference operation with `model.name` and `gen_ai.request.max_tokens`
- **Duration bars**: visual representation of time spent in each span (inference is nested inside the gateway span)
- **Tags/attributes**: metadata like HTTP status, model name, token counts

### Service map

The **Node Graph** panel in the Trace Exploration dashboard (or in Explore > Tempo > Service Map) shows:
- Nodes for each service emitting traces
- Edges showing request flow between services
- Latency and error rate on each edge

### Traces to metrics correlation

The Tempo datasource is configured with `tracesToMetrics` pointing to Thanos Querier. This means:
- From a trace span, click **"Related metrics"** to jump to Prometheus metrics for that service
- Correlate a slow trace with CPU/memory/KV cache metrics at that point in time

## Metrics Propagation Timing

After generating traffic, metrics appear in dashboards at different speeds:

| Source | Delay | Why |
|--------|-------|-----|
| vLLM metrics (via PodMonitor) | 30-60s | Prometheus scrape interval + Thanos propagation |
| Gateway metrics (Kuadrant/Envoy) | 15-30s | Scraped from platform monitoring |
| Trace-derived metrics (spanmetrics) | 5-15s | Near real-time from OTel Collector |
| Traces in Tempo | 1-5s | OTLP push, near-instant storage |

If panels remain empty after 2 minutes of traffic, check:
1. `oc get pods -n maas-models` -- are model pods running?
2. `oc get pods -n observability` -- are Grafana, Collector, Tempo running?
3. `oc get podmonitor -n maas-models` -- does the PodMonitor exist?
4. `oc get grafanadatasource -n observability` -- are datasources created?

## Gateway Errors

There are **two distinct sources** of 5xx errors in the MaaS gateway. The dashboard tracks both separately.

### Type 1: Auth Timeout (WASM filter)

The Kuadrant WASM filter in Envoy has a hardcoded `auth-service` timeout of **200ms** (`failureMode: deny`). The authentication chain (TokenReview + tier HTTP callback to MaaS API) can exceed 200ms under concurrent load or when auth caches are cold. When this happens, the WASM filter returns 500 -- the request **never reaches vLLM**.

Evidence:
- `kuadrant_errors` metric counts these (scraped from Envoy gateway pod via istio-pod-monitor)
- Envoy access logs show 500 responses with exactly ~200ms duration and upstream `"-"`
- With `CONCURRENCY<=2` and warm cache, no auth timeouts occur

### Type 2: Backend Error (vLLM)

Even when requests pass auth+ratelimit, vLLM itself can return 5xx (e.g. overloaded, OOM, model errors). These are tracked by `istio_requests_total{source_workload="maas-default-gateway-openshift-default", response_code=~"5.."}`.

### Why HAProxy metrics don't work

The `maas-default-gateway` OpenShift Route uses **TLS passthrough**. HAProxy cannot see HTTP status codes for passthrough routes, so `haproxy_server_http_responses_total` is always empty for MaaS traffic.

### Where to see them

| Source | How to check |
|--------|-------------|
| **Dashboard** | "MaaS Platform Overview" > "Error Rate/sec" stat (combined) and "Request Outcomes Over Time" chart (separated by type) |
| **Prometheus alerts** | `MaaSGatewayAuthTimeout` (WASM errors 2min), `MaaSBackend5xx` (vLLM errors 2min), `MaaSGatewayErrorsCritical` (combined >5% for 5min) |
| **Auth timeout metric** | `kuadrant_errors` |
| **Backend error metric** | `istio_requests_total{source_workload="maas-default-gateway-openshift-default", response_code=~"5.."}` |
| **Envoy WASM stats** | `oc exec -n openshift-ingress <gateway-pod> -c istio-proxy -- pilot-agent request GET stats \| grep kuadrant` |
| **Envoy access logs** | `oc logs -n openshift-ingress <gateway-pod> -c istio-proxy --tail=100 \| grep 500` |

### Production mitigations

- **Limit client concurrency**: Keep `CONCURRENCY<=2` for the traffic generator. In production, implement client-side rate limiting to avoid bursting above what the auth chain can handle in 200ms
- **Kuadrant WASM auth timeout**: The 200ms is hardcoded by the Kuadrant operator (`WasmPlugin` gets reconciled back). Upstream Kuadrant issue needed to make this configurable
- **AuthPolicy cache TTLs**: Identity cache 600s, tier cache 300s, authorization cache 60s. Cached auth evaluations are fast enough to avoid the 200ms timeout
- **Authorino resources**: Ensure adequate CPU/memory so auth evaluation completes within 200ms under load
- **vLLM scaling**: Monitor backend errors; if vLLM returns 5xx under load, scale replicas or increase resources
- **Retry with backoff**: Clients should implement retry with exponential backoff for 5xx responses

### About the port-forward in generate-traffic.sh

The traffic generator uses `oc port-forward` to send OTLP traces to the OTel Collector from your local machine. This is a **dev-only workaround** because the script runs outside the cluster and cannot reach the collector service directly.

In production, traces are emitted by application pods running inside the cluster (vLLM with OTEL packages, or gateway with Istio Telemetry). They connect directly to the collector service (`maas-collector-collector.observability.svc:4317`) without any port-forward.
