#!/usr/bin/env bash
# EvalHub API wrapper — submit evaluations, check status, list providers/collections.
# Auth: uses `oc whoami -t` for Bearer token + X-Tenant header.
#
# Usage:
#   ./scripts/evalhub.sh providers                           # list providers
#   ./scripts/evalhub.sh collections                         # list collections
#   ./scripts/evalhub.sh submit --provider lm_evaluation_harness --benchmark arc_easy \
#       --model-url https://rh-ai.apps.cluster/v1 --model-name TinyLlama/... [--limit 10] [--wait]
#   ./scripts/evalhub.sh submit --provider guidellm --benchmark sweep \
#       --model-url https://rh-ai.apps.cluster/v1 --model-name tinyllama-test [--wait]
#   ./scripts/evalhub.sh status <job-id>
#   ./scripts/evalhub.sh jobs                                # list all jobs

set -euo pipefail

OC="${OC:-oc}"
EVALHUB_NAMESPACE="${EVALHUB_NAMESPACE:-evaluation}"
EVALHUB_TENANT="${EVALHUB_TENANT:-evaluation}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
POLL_TIMEOUT="${POLL_TIMEOUT:-1800}"

_evalhub_url() {
  local route_host
  route_host=$($OC get route evalhub -n "$EVALHUB_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null) || {
    echo "ERROR: EvalHub route not found in namespace $EVALHUB_NAMESPACE" >&2
    exit 1
  }
  echo "https://${route_host}"
}

_token() {
  $OC whoami -t 2>/dev/null || {
    echo "ERROR: not logged into OpenShift (oc whoami -t failed)" >&2
    exit 1
  }
}

_curl() {
  local method="$1" path="$2"
  shift 2
  local base_url token
  base_url=$(_evalhub_url)
  token=$(_token)
  curl -sk -X "$method" \
    -H "Authorization: Bearer $token" \
    -H "X-Tenant: $EVALHUB_TENANT" \
    -H "Content-Type: application/json" \
    "$@" \
    "${base_url}${path}"
}

cmd_providers() {
  _curl GET "/api/v1/evaluations/providers?benchmarks=true"
}

cmd_collections() {
  _curl GET "/api/v1/evaluations/collections"
}

cmd_jobs() {
  _curl GET "/api/v1/evaluations/jobs"
}

cmd_status() {
  local job_id="${1:?Usage: evalhub.sh status <job-id>}"
  _curl GET "/api/v1/evaluations/jobs/$job_id"
}

cmd_submit() {
  local provider="" benchmark="" model_url="" model_name="" name="" limit="" wait_flag=false
  local extra_params=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider)   provider="$2"; shift 2 ;;
      --benchmark)  benchmark="$2"; shift 2 ;;
      --model-url)  model_url="$2"; shift 2 ;;
      --model-name) model_name="$2"; shift 2 ;;
      --name)       name="$2"; shift 2 ;;
      --limit)      limit="$2"; shift 2 ;;
      --wait)       wait_flag=true; shift ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  : "${provider:?--provider is required (e.g. lm_evaluation_harness, guidellm)}"
  : "${benchmark:?--benchmark is required (e.g. arc_easy, sweep)}"
  : "${model_url:?--model-url is required}"
  : "${model_name:?--model-name is required}"

  [[ -z "$name" ]] && name="${model_name##*/}-${benchmark}-$(date +%Y%m%d-%H%M%S)"
  name=$(echo "$name" | tr '/' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-63)

  local params="{}"
  if [[ -n "$limit" ]]; then
    params="{\"limit\": $limit}"
  fi

  local body
  body=$(cat <<EOF
{
  "name": "$name",
  "model": {
    "url": "$model_url",
    "name": "$model_name"
  },
  "benchmarks": [{
    "id": "$benchmark",
    "provider_id": "$provider",
    "parameters": $params
  }]
}
EOF
  )

  echo "Submitting evaluation job..." >&2
  echo "  Provider:  $provider" >&2
  echo "  Benchmark: $benchmark" >&2
  echo "  Model:     $model_name" >&2
  echo "  URL:       $model_url" >&2
  [[ -n "$limit" ]] && echo "  Limit:     $limit" >&2

  local response
  response=$(_curl POST "/api/v1/evaluations/jobs" -d "$body")

  local job_id state
  job_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['resource']['id'])" 2>/dev/null) || {
    echo "ERROR: Failed to submit job:" >&2
    echo "$response" >&2
    exit 1
  }
  state=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['state'])" 2>/dev/null)

  echo "  Job ID:    $job_id" >&2
  echo "  State:     $state" >&2

  if [[ "$wait_flag" == "true" ]]; then
    _wait_for_job "$job_id"
  else
    echo "$response"
  fi
}

_wait_for_job() {
  local job_id="$1"
  local elapsed=0

  echo "Waiting for job $job_id to complete (timeout: ${POLL_TIMEOUT}s)..." >&2

  while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
    local response state
    response=$(_curl GET "/api/v1/evaluations/jobs/$job_id")
    state=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['state'])" 2>/dev/null)

    case "$state" in
      completed)
        echo "Job completed successfully." >&2
        echo "$response"
        return 0
        ;;
      failed)
        local msg
        msg=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['message']['message'])" 2>/dev/null)
        echo "ERROR: Job failed: $msg" >&2
        echo "$response"
        return 1
        ;;
      *)
        echo "  [${elapsed}s] State: $state" >&2
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        ;;
    esac
  done

  echo "ERROR: Timed out waiting for job $job_id" >&2
  return 1
}

cmd_help() {
  cat <<'USAGE'
EvalHub API wrapper — submit evaluations via the RHOAI EvalHub control plane.

Commands:
  providers                List available evaluation providers and benchmarks
  collections              List benchmark collections (e.g. leaderboard-v2)
  jobs                     List all evaluation jobs
  status <job-id>          Get status and results of a specific job
  submit [options]         Submit a new evaluation job

Submit options:
  --provider <id>          Provider: lm_evaluation_harness, guidellm, garak, lighteval
  --benchmark <id>         Benchmark ID (e.g. arc_easy, sweep, leaderboard_ifeval)
  --model-url <url>        Model endpoint URL (e.g. https://rh-ai.apps.cluster/v1)
  --model-name <name>      Model name (e.g. TinyLlama/TinyLlama-1.1B-Chat-v1.0)
  --name <name>            Job name (auto-generated if omitted)
  --limit <n>              Limit number of samples (lm-eval only)
  --wait                   Wait for job to complete (polls every 15s)

Environment:
  OC                       oc binary path (default: oc)
  EVALHUB_NAMESPACE        EvalHub namespace (default: evaluation)
  EVALHUB_TENANT           X-Tenant header (default: evaluation)
  POLL_INTERVAL            Seconds between status polls (default: 15)
  POLL_TIMEOUT             Max wait time in seconds (default: 1800)

Examples:
  # Quality evaluation (lm-evaluation-harness)
  ./scripts/evalhub.sh submit --provider lm_evaluation_harness --benchmark arc_easy \
      --model-url https://rh-ai.apps.cluster/v1 \
      --model-name TinyLlama/TinyLlama-1.1B-Chat-v1.0 --limit 10 --wait

  # Performance benchmark (guidellm)
  ./scripts/evalhub.sh submit --provider guidellm --benchmark sweep \
      --model-url https://rh-ai.apps.cluster/v1 \
      --model-name tinyllama-test --wait

  # Run leaderboard-v2 collection (all 6 benchmarks via individual submits)
  for bench in leaderboard_ifeval leaderboard_bbh leaderboard_gpqa \
               leaderboard_mmlu_pro leaderboard_musr leaderboard_math_hard; do
    ./scripts/evalhub.sh submit --provider lm_evaluation_harness --benchmark "$bench" \
        --model-url https://rh-ai.apps.cluster/v1 \
        --model-name MyModel/name --limit 100
  done
USAGE
}

case "${1:-help}" in
  providers)    cmd_providers ;;
  collections)  cmd_collections ;;
  jobs)         cmd_jobs ;;
  status)       shift; cmd_status "$@" ;;
  submit)       shift; cmd_submit "$@" ;;
  help|--help|-h) cmd_help ;;
  *) echo "Unknown command: $1. Run '$0 help' for usage." >&2; exit 1 ;;
esac
