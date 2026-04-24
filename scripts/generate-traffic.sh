#!/usr/bin/env bash
#
# Generate inference traffic against the MaaS gateway to populate
# Grafana dashboards (metrics) and Tempo traces.
#
# Usage:
#   ./scripts/generate-traffic.sh
#   REQUESTS=100 CONCURRENCY=4 DELAY=0.5 ./scripts/generate-traffic.sh
#   MODELS=tinyllama-test ./scripts/generate-traffic.sh
#   make generate-traffic
#
# Environment variables:
#   REQUESTS     Total requests to send (default: 50)
#   CONCURRENCY  Parallel workers (default: 2; keep <=2 to avoid gateway 500s)
#   DELAY        Seconds between requests per worker (default: 1)
#   MODELS       Comma-separated model list (default: tinyllama-test,tinyllama-fast)
#   MAX_TOKENS   Max tokens per request (default: 30)
#   EMIT_TRACES  Send OTLP traces to collector (default: true)
#   COLLECTOR_HOST  OTel collector host:port for OTLP HTTP (default: auto via port-forward)
#
# NOTE on CONCURRENCY: The Kuadrant WASM filter has a hardcoded auth-service
# timeout of 200ms. Under high concurrency (>=4 workers), the auth evaluation
# chain (TokenReview + tier lookup) can exceed this limit, causing 500 errors
# from the WASM filter (not from vLLM). Keep CONCURRENCY<=2 until Kuadrant
# makes this timeout configurable. See docs/DASHBOARDS.md for details.

set -euo pipefail

OC="${OC:-oc}"
REQUESTS="${REQUESTS:-50}"
CONCURRENCY="${CONCURRENCY:-2}"
DELAY="${DELAY:-1}"
MODELS="${MODELS:-tinyllama-test,tinyllama-fast}"
MAX_TOKENS="${MAX_TOKENS:-30}"
EMIT_TRACES="${EMIT_TRACES:-true}"
COLLECTOR_HOST="${COLLECTOR_HOST:-maas-collector-collector.observability.svc:4318}"

IFS=',' read -ra MODEL_LIST <<< "$MODELS"

PROMPTS=(
  "Say hello in one word"
  "Explain what Kubernetes is in two sentences"
  "Write a short poem about containers and orchestration in the cloud. Include references to pods, services, and deployments."
  "What is 2+2?"
  "List three benefits of using OpenShift for enterprise workloads and explain each one briefly"
  "Describe the difference between a Deployment and a StatefulSet in Kubernetes. When would you use each?"
  "Tell me a joke"
  "Summarize the concept of GitOps in one paragraph. Include how ArgoCD fits into the workflow."
)
PROMPT_COUNT=${#PROMPTS[@]}

# ── Discover cluster ────────────────────────────────────────────────
echo "=== MaaS Traffic Generator ==="
echo ""

CLUSTER_DOMAIN=$($OC get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null) || {
  echo "ERROR: cannot read cluster domain. Are you logged in? (oc login)" >&2
  exit 1
}
MAAS_HOST="maas.${CLUSTER_DOMAIN}"
MAAS_URL="https://${MAAS_HOST}"

echo "Cluster domain : ${CLUSTER_DOMAIN}"
echo "MaaS endpoint  : ${MAAS_URL}"
echo "Models         : ${MODELS}"
echo "Requests       : ${REQUESTS}"
echo "Concurrency    : ${CONCURRENCY}"
echo "Delay          : ${DELAY}s"
echo "Max tokens     : ${MAX_TOKENS}"
echo ""

# ── Obtain MaaS token ──────────────────────────────────────────────
OC_TOKEN=$($OC whoami -t 2>/dev/null) || {
  echo "ERROR: cannot get oc token. Are you logged in?" >&2
  exit 1
}

echo "Obtaining MaaS token..."
TOKEN_RESP=$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/tokens" \
  -H "Authorization: Bearer ${OC_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"expiration":"60m"}')

MAAS_TOKEN=$(echo "$TOKEN_RESP" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
if [[ -z "$MAAS_TOKEN" ]]; then
  echo "ERROR: failed to obtain MaaS token. Response: ${TOKEN_RESP}" >&2
  exit 1
fi
echo "Token obtained (expires in 60m)"
echo ""

# ── OTLP trace port-forward (dev-only) ───────────────────────────
# This port-forward is needed because the script runs outside the cluster
# and cannot reach the OTel Collector service directly. In production,
# application pods emit traces from inside the cluster to the collector
# service (maas-collector-collector.observability.svc:4317) -- no port-forward.
TMPDIR=$(mktemp -d)
PF_PID=""

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

OTLP_URL=""
if [[ "$EMIT_TRACES" == "true" ]]; then
  echo "Starting port-forward to OTel Collector (OTLP HTTP)..."
  PF_PORT=$(shuf -i 20000-30000 -n 1)
  $OC port-forward -n observability svc/maas-collector-collector "${PF_PORT}:4318" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 2
  if kill -0 "$PF_PID" 2>/dev/null; then
    OTLP_URL="http://localhost:${PF_PORT}/v1/traces"
    echo "OTLP endpoint  : ${OTLP_URL}"
  else
    echo "WARN: port-forward failed, traces will be skipped"
    EMIT_TRACES="false"
    PF_PID=""
  fi
  echo ""
fi

echo "0" > "$TMPDIR/success"
echo "0" > "$TMPDIR/fail"
echo "0" > "$TMPDIR/traces"

rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c $(($1 * 2)); }

emit_trace() {
  local model="$1" route="$2" status_code="$3" start_ns="$4" end_ns="$5"
  [[ "$EMIT_TRACES" != "true" ]] && return 0

  local trace_id span_id_gw span_id_infer
  trace_id=$(rand_hex 16)
  span_id_gw=$(rand_hex 8)
  span_id_infer=$(rand_hex 8)

  local payload
  payload=$(cat <<EOOTLP
{"resourceSpans":[
  {"resource":{"attributes":[
    {"key":"service.name","value":{"stringValue":"maas-gateway"}},
    {"key":"service.version","value":{"stringValue":"1.0.0"}}
  ]},"scopeSpans":[{"scope":{"name":"maas-traffic-gen","version":"1.0"},"spans":[
    {"traceId":"${trace_id}","spanId":"${span_id_gw}","name":"POST ${route}","kind":2,
     "startTimeUnixNano":"${start_ns}","endTimeUnixNano":"${end_ns}",
     "attributes":[
       {"key":"http.method","value":{"stringValue":"POST"}},
       {"key":"http.route","value":{"stringValue":"${route}"}},
       {"key":"http.status_code","value":{"intValue":"${status_code}"}},
       {"key":"model.name","value":{"stringValue":"${model}"}}
     ],"status":{"code":$([ "$status_code" -eq 200 ] && echo 1 || echo 2)}}
  ]}]},
  {"resource":{"attributes":[
    {"key":"service.name","value":{"stringValue":"vllm-${model}"}},
    {"key":"service.version","value":{"stringValue":"1.0.0"}}
  ]},"scopeSpans":[{"scope":{"name":"vllm.inference","version":"1.0"},"spans":[
    {"traceId":"${trace_id}","spanId":"${span_id_infer}","parentSpanId":"${span_id_gw}",
     "name":"inference ${model}","kind":3,
     "startTimeUnixNano":"$(( start_ns + 5000000 ))","endTimeUnixNano":"$(( end_ns - 2000000 ))",
     "attributes":[
       {"key":"model.name","value":{"stringValue":"${model}"}},
       {"key":"gen_ai.request.max_tokens","value":{"intValue":"${MAX_TOKENS}"}}
     ],"status":{"code":$([ "$status_code" -eq 200 ] && echo 1 || echo 2)}}
  ]}]}
]}
EOOTLP
)

  if curl -sf -o /dev/null -X POST "$OTLP_URL" \
       -H "Content-Type: application/json" \
       -d "$payload" --max-time 5 2>/dev/null; then
    flock "$TMPDIR/traces" bash -c 'echo $(( $(cat "'"$TMPDIR/traces"'") + 1 )) > "'"$TMPDIR/traces"'"'
  fi
}

send_request() {
  local req_num=$1
  local model=${MODEL_LIST[$((req_num % ${#MODEL_LIST[@]}))]}
  local prompt=${PROMPTS[$((req_num % PROMPT_COUNT))]}

  local payload
  payload=$(cat <<EOJSON
{
  "model": "${model}",
  "messages": [{"role": "user", "content": "${prompt}"}],
  "max_tokens": ${MAX_TOKENS}
}
EOJSON
)

  local route="/maas-models/${model}/v1/chat/completions"
  local start_ns
  start_ns=$(date +%s%N)

  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X POST "${MAAS_URL}${route}" \
    -H "Authorization: Bearer ${MAAS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 120)

  local end_ns
  end_ns=$(date +%s%N)

  if [[ "$http_code" == "200" ]]; then
    echo "  [${req_num}/${REQUESTS}] ${model} -> ${http_code} OK"
    flock "$TMPDIR/success" bash -c 'echo $(( $(cat "'"$TMPDIR/success"'") + 1 )) > "'"$TMPDIR/success"'"'
  else
    echo "  [${req_num}/${REQUESTS}] ${model} -> ${http_code} FAIL"
    flock "$TMPDIR/fail" bash -c 'echo $(( $(cat "'"$TMPDIR/fail"'") + 1 )) > "'"$TMPDIR/fail"'"'
  fi

  emit_trace "$model" "$route" "$http_code" "$start_ns" "$end_ns"
}

# ── Main loop ──────────────────────────────────────────────────────
echo "Sending ${REQUESTS} requests (${CONCURRENCY} workers, ${DELAY}s delay)..."
echo ""

START_TIME=$(date +%s)
REQ_PIDS=()

for ((i=1; i<=REQUESTS; i++)); do
  send_request "$i" &
  REQ_PIDS+=($!)

  if [[ ${#REQ_PIDS[@]} -ge $CONCURRENCY ]]; then
    wait "${REQ_PIDS[0]}" 2>/dev/null || true
    REQ_PIDS=("${REQ_PIDS[@]:1}")
  fi

  sleep "$DELAY"
done

for pid in "${REQ_PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
SUCCESS=$(cat "$TMPDIR/success")
FAIL=$(cat "$TMPDIR/fail")
TRACES=$(cat "$TMPDIR/traces" 2>/dev/null || echo 0)

echo ""
echo "=== Summary ==="
echo "Total requests : ${REQUESTS}"
echo "Succeeded      : ${SUCCESS}"
echo "Failed         : ${FAIL}"
echo "Traces sent    : ${TRACES}"
echo "Elapsed        : ${ELAPSED}s"
echo ""
echo "Dashboard data and traces should now be visible in Grafana."
echo "Run: oc get route grafana-route -n observability -o jsonpath='{.spec.host}'"
echo "Open: https://<grafana-host> and explore the dashboards."
