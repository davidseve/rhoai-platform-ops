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
#   CONCURRENCY  Parallel workers (default: 2)
#   DELAY        Seconds between requests per worker (default: 1)
#   MODELS       Comma-separated model list (default: tinyllama-test,tinyllama-fast)
#   MAX_TOKENS   Max tokens per request (default: 30)

set -euo pipefail

OC="${OC:-oc}"
REQUESTS="${REQUESTS:-50}"
CONCURRENCY="${CONCURRENCY:-2}"
DELAY="${DELAY:-1}"
MODELS="${MODELS:-tinyllama-test,tinyllama-fast}"
MAX_TOKENS="${MAX_TOKENS:-30}"

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

# ── Counters (shared via temp files) ───────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "0" > "$TMPDIR/success"
echo "0" > "$TMPDIR/fail"

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

  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X POST "${MAAS_URL}/maas-models/${model}/v1/chat/completions" \
    -H "Authorization: Bearer ${MAAS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 120)

  if [[ "$http_code" == "200" ]]; then
    echo "  [${req_num}/${REQUESTS}] ${model} -> ${http_code} OK"
    flock "$TMPDIR/success" bash -c 'echo $(( $(cat "'"$TMPDIR/success"'") + 1 )) > "'"$TMPDIR/success"'"'
  else
    echo "  [${req_num}/${REQUESTS}] ${model} -> ${http_code} FAIL"
    flock "$TMPDIR/fail" bash -c 'echo $(( $(cat "'"$TMPDIR/fail"'") + 1 )) > "'"$TMPDIR/fail"'"'
  fi
}

# ── Main loop ──────────────────────────────────────────────────────
echo "Sending ${REQUESTS} requests (${CONCURRENCY} workers, ${DELAY}s delay)..."
echo ""

START_TIME=$(date +%s)
active=0

for ((i=1; i<=REQUESTS; i++)); do
  send_request "$i" &
  active=$((active + 1))

  if [[ $active -ge $CONCURRENCY ]]; then
    wait -n 2>/dev/null || true
    active=$((active - 1))
  fi

  sleep "$DELAY"
done

wait

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
SUCCESS=$(cat "$TMPDIR/success")
FAIL=$(cat "$TMPDIR/fail")

echo ""
echo "=== Summary ==="
echo "Total requests : ${REQUESTS}"
echo "Succeeded      : ${SUCCESS}"
echo "Failed         : ${FAIL}"
echo "Elapsed        : ${ELAPSED}s"
echo ""
echo "Dashboard data should now be visible in Grafana."
echo "Run: oc get route grafana-route -n observability -o jsonpath='{.spec.host}'"
echo "Open: https://<grafana-host> and explore the dashboards."
