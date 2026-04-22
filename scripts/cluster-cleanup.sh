#!/usr/bin/env bash
#
# Cluster cleanup for rhoai-platform-ops.
# Removes all deployed resources in reverse order (wave 2 -> 1 -> 0).
#
# Usage:
#   ./scripts/cluster-cleanup.sh                       # full cleanup (asks confirmation)
#   ./scripts/cluster-cleanup.sh maas                  # cleanup only the maas module
#   ./scripts/cluster-cleanup.sh --yes                 # skip confirmation
#   DRY_RUN=true ./scripts/cluster-cleanup.sh          # show what would be deleted
#   WAIT_TIMEOUT=180 ./scripts/cluster-cleanup.sh      # custom namespace wait timeout
#
# Update this script when adding new modules or changing namespaces/CRDs.

set -euo pipefail

OC="${OC:-oc}"
DRY_RUN="${DRY_RUN:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"
CONFIRM="${CONFIRM:-false}"
MODULE=""

for arg in "$@"; do
  case "$arg" in
    --yes|-y) CONFIRM=true ;;
    --dry-run) DRY_RUN=true ;;
    -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
    *) MODULE="$arg" ;;
  esac
done

log()  { echo "[cleanup] $*"; }
warn() { echo "[cleanup] WARNING: $*" >&2; }
run()  {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $*"
  else
    eval "$@" || true
  fi
}

confirm_or_exit() {
  if [[ "$DRY_RUN" == "true" || "$CONFIRM" == "true" ]]; then return 0; fi
  echo ""
  log "Cluster: $($OC whoami --show-server)"
  log "User: $($OC whoami)"
  if [[ -n "$MODULE" ]]; then
    log "Module: $MODULE"
  else
    log "Scope: ALL modules"
  fi
  echo ""
  read -r -p "[cleanup] This will DELETE resources from the cluster. Continue? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) log "Aborted."; exit 0 ;;
  esac
}

wait_ns_gone() {
  local ns="$1"
  local timeout="${2:-$WAIT_TIMEOUT}"
  if [[ "$DRY_RUN" == "true" ]]; then return 0; fi
  if ! $OC get ns "$ns" &>/dev/null; then return 0; fi
  log "Waiting up to ${timeout}s for namespace $ns to terminate..."
  local elapsed=0
  while $OC get ns "$ns" &>/dev/null; do
    if (( elapsed >= timeout )); then
      warn "Namespace $ns still exists after ${timeout}s -- attempting finalizer cleanup"
      force_delete_ns "$ns"
      return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  log "Namespace $ns deleted"
}

force_delete_ns() {
  local ns="$1"
  log "Force-cleaning namespace $ns (clearing blocking finalizers)..."

  for resource in $($OC api-resources --verbs=list --namespaced -o name 2>/dev/null); do
    for item in $($OC get "$resource" -n "$ns" -o name 2>/dev/null); do
      run "$OC patch '$item' -n '$ns' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    done
  done

  run "$OC delete ns '$ns' --timeout=30s --ignore-not-found"
}

# ============================================================
# Module: MaaS -- Models (wave 2)
# ============================================================
cleanup_helm_releases() {
  log "=== Removing Helm releases (if any) ==="
  if ! command -v helm &>/dev/null; then
    log "  helm not found, skipping Helm release cleanup"
    return 0
  fi
  for release in maas-model-fast maas-model maas-platform maas-operators obs-grafana obs-operators; do
    local status
    status=$(helm status "$release" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 || true)
    if [[ -z "$status" ]]; then continue; fi
    log "  Uninstalling $release ($status)..."
    if ! run "helm uninstall '$release' --wait --timeout 2m"; then
      log "  helm uninstall failed for $release -- force-removing release secrets"
      run "$OC delete secret -n default -l name='$release',owner=helm --ignore-not-found"
    fi
  done
  # Clean any releases stuck in pending-install / uninstalling from a previous failed run
  for secret in $($OC get secret -n default -l owner=helm -o name 2>/dev/null | grep -E 'maas-|rhoai-|obs-' || true); do
    log "  Removing leftover Helm secret: $secret"
    run "$OC delete '$secret' -n default --ignore-not-found"
  done
}

cleanup_maas_models() {
  log "=== MaaS: Cleaning up models (wave 2) ==="

  local model_ns="maas-models"
  local gateway_ns="openshift-ingress"

  if $OC get ns "$model_ns" &>/dev/null; then
    log "Clearing LLMInferenceService finalizers in $model_ns..."
    for lis in $($OC get llminferenceservice -n "$model_ns" -o name 2>/dev/null); do
      run "$OC patch '$lis' -n '$model_ns' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    done

    log "Deleting LLMInferenceService resources..."
    run "$OC delete llminferenceservice --all -n '$model_ns' --timeout=60s --ignore-not-found"

    log "Deleting rate limit policies..."
    run "$OC delete ratelimitpolicy --all -n '$model_ns' --timeout=30s --ignore-not-found"
    run "$OC delete tokenratelimitpolicy --all -n '$model_ns' --timeout=30s --ignore-not-found"

    log "Deleting RBAC resources..."
    run "$OC delete rolebinding --all -n '$model_ns' --timeout=10s --ignore-not-found"
    run "$OC delete role --all -n '$model_ns' --timeout=10s --ignore-not-found"
  fi

  log "Cleaning up cleanup-authn-hook resources in $gateway_ns..."
  run "$OC delete job patch-gateway-authn -n '$gateway_ns' --ignore-not-found"
  run "$OC delete job -l argocd.argoproj.io/hook=PostSync -n '$gateway_ns' --ignore-not-found"
  run "$OC delete rolebinding patch-gateway-authn -n '$gateway_ns' --ignore-not-found"
  run "$OC delete role patch-gateway-authn -n '$gateway_ns' --ignore-not-found"
  run "$OC delete sa patch-gateway-authn -n '$gateway_ns' --ignore-not-found"

  log "Deleting namespace $model_ns..."
  run "$OC delete ns '$model_ns' --timeout=60s --ignore-not-found"
  wait_ns_gone "$model_ns" 90
}

# ============================================================
# Module: MaaS -- Platform (wave 1)
# ============================================================
cleanup_maas_platform() {
  log "=== MaaS: Cleaning up platform (wave 1) ==="

  local gateway_ns="openshift-ingress"
  local kuadrant_ns="kuadrant-system"

  log "Deleting Route and Gateway..."
  run "$OC delete route maas-default-gateway -n '$gateway_ns' --ignore-not-found"
  run "$OC delete gateway maas-default-gateway -n '$gateway_ns' --ignore-not-found"
  run "$OC delete gatewayclass openshift-default --ignore-not-found"
  run "$OC delete gatewayclass kuadrant-multi-cluster-gateway-instance-per-cluster --ignore-not-found"

  log "Deleting TelemetryPolicy..."
  run "$OC delete telemetrypolicy -n '$gateway_ns' --all --ignore-not-found"

  log "Deleting monitoring resources..."
  run "$OC delete servicemonitor -n '$kuadrant_ns' --all --ignore-not-found"
  run "$OC delete prometheusrule -n '$kuadrant_ns' --all --ignore-not-found"

  log "Deleting Limitador patch..."
  run "$OC delete limitador limitador -n '$kuadrant_ns' --ignore-not-found"

  log "Deleting Kuadrant readiness hook resources..."
  run "$OC delete job -l argocd.argoproj.io/hook=PostSync -n '$kuadrant_ns' --ignore-not-found"
  run "$OC delete clusterrolebinding kuadrant-readiness-check --ignore-not-found"
  run "$OC delete clusterrole kuadrant-readiness-check --ignore-not-found"
  run "$OC delete sa kuadrant-readiness-check -n '$kuadrant_ns' --ignore-not-found"

  log "Deleting tier-to-group-mapping ConfigMap..."
  run "$OC delete configmap tier-to-group-mapping -n redhat-ods-applications --ignore-not-found"

  log "Deleting OdhDashboardConfig..."
  run "$OC delete odhdashboardconfig -n redhat-ods-applications --all --ignore-not-found"

  log "Deleting DataScienceCluster and DSCInitialization..."
  run "$OC delete datasciencecluster --all --timeout=120s --ignore-not-found"
  run "$OC delete dscinitialization --all --timeout=120s --ignore-not-found"

  log "Deleting OpenShift Groups (resource-policy: keep)..."
  for group in $($OC get group -o name 2>/dev/null | grep 'tier-'); do
    run "$OC delete '$group' --ignore-not-found"
  done

  log "Deleting gateway tier namespaces (created by AuthPolicy)..."
  for ns in $($OC get ns -o name 2>/dev/null | grep 'maas-default-gateway-tier-'); do
    run "$OC delete '$ns' --timeout=60s --ignore-not-found"
  done
  for ns in $($OC get ns -o name 2>/dev/null | grep 'maas-default-gateway-tier-'); do
    local tier_ns
    tier_ns=$(echo "$ns" | sed 's|namespace/||')
    wait_ns_gone "$tier_ns" 60
  done
}

# ============================================================
# Module: MaaS -- Operators (wave 0)
# ============================================================
cleanup_maas_operators() {
  log "=== MaaS: Cleaning up operators (wave 0) ==="

  log "Deleting Kuadrant CR..."
  run "$OC delete kuadrant --all -n kuadrant-system --timeout=60s --ignore-not-found"

  log "Deleting LeaderWorkerSetOperator CR..."
  run "$OC delete leaderworkersetoperator --all --timeout=60s --ignore-not-found"

  log "Deleting operator subscriptions..."
  run "$OC delete subscription --all -n redhat-ods-operator --ignore-not-found"
  run "$OC delete subscription --all -n kuadrant-system --ignore-not-found"
  run "$OC delete subscription --all -n leader-worker-set --ignore-not-found"

  log "Deleting CSVs..."
  run "$OC delete csv --all -n redhat-ods-operator --ignore-not-found"
  run "$OC delete csv --all -n kuadrant-system --ignore-not-found"
  run "$OC delete csv --all -n leader-worker-set --ignore-not-found"

  log "Deleting OperatorGroups..."
  run "$OC delete operatorgroup --all -n redhat-ods-operator --ignore-not-found"
  run "$OC delete operatorgroup --all -n kuadrant-system --ignore-not-found"
  run "$OC delete operatorgroup --all -n leader-worker-set --ignore-not-found"

  log "Deleting RHOAI-managed namespaces..."
  run "$OC delete ns redhat-ods-applications --timeout=120s --ignore-not-found"
  run "$OC delete ns redhat-ods-monitoring --timeout=60s --ignore-not-found"

  log "Deleting operator namespaces..."
  run "$OC delete ns redhat-ods-operator --timeout=60s --ignore-not-found"
  run "$OC delete ns kuadrant-system --timeout=60s --ignore-not-found"
  run "$OC delete ns leader-worker-set --timeout=60s --ignore-not-found"

  wait_ns_gone "redhat-ods-applications" 120
  wait_ns_gone "redhat-ods-monitoring" 90
  wait_ns_gone "redhat-ods-operator" 90
  wait_ns_gone "kuadrant-system" 90
  wait_ns_gone "leader-worker-set" 60
}

# ============================================================
# Module: Observability
# ============================================================
cleanup_observability() {
  log "=== Observability: Cleaning up ==="

  log "Deleting Grafana CRs..."
  run "$OC delete grafanadashboard --all -A --ignore-not-found"
  run "$OC delete grafanadatasource --all -A --ignore-not-found"
  run "$OC delete grafana --all -n observability --ignore-not-found"

  log "Deleting Grafana Operator subscription (global)..."
  run "$OC delete subscription grafana-operator -n openshift-operators --ignore-not-found"
  for csv in $($OC get csv -n openshift-operators -o name 2>/dev/null | grep grafana-operator || true); do
    run "$OC delete '$csv' -n openshift-operators --ignore-not-found"
  done

  log "Deleting RBAC..."
  run "$OC delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found"
  run "$OC delete clusterrole grafana-proxy-observability --ignore-not-found"

  log "Deleting namespace observability..."
  run "$OC delete ns observability --timeout=60s --ignore-not-found"
  wait_ns_gone "observability" 90
}

# ============================================================
# ArgoCD
# ============================================================
cleanup_argocd() {
  log "=== Removing ArgoCD Applications ==="

  log "Deleting child applications..."
  for app in maas-model-fast maas-model maas-platform maas-operators observability-grafana observability-operators; do
    run "$OC delete application '$app' -n openshift-gitops --ignore-not-found"
  done

  log "Deleting app-of-apps..."
  run "$OC delete application rhoai-platform-ops -n openshift-gitops --ignore-not-found"

  log "Waiting for ArgoCD apps to be removed..."
  sleep 5
}

# ============================================================
# Post-cleanup verification
# ============================================================
verify_cleanup() {
  if [[ "$DRY_RUN" == "true" ]]; then return 0; fi
  log ""
  log "=== Verification ==="
  local failed=0

  local namespaces=(
    "maas-models"
    "redhat-ods-applications"
    "redhat-ods-monitoring"
    "redhat-ods-operator"
    "kuadrant-system"
    "leader-worker-set"
    "observability"
  )
  # Add dynamic tier namespaces to verification
  for ns in $($OC get ns -o name 2>/dev/null | grep 'maas-default-gateway-tier-' | sed 's|namespace/||'); do
    namespaces+=("$ns")
  done
  # -- Add new module namespaces here --

  for ns in "${namespaces[@]}"; do
    if $OC get ns "$ns" &>/dev/null; then
      warn "Namespace $ns still exists"
      failed=1
    else
      log "  $ns -- gone"
    fi
  done

  local apps
  apps=$($OC get applications.argoproj.io -n openshift-gitops -o name 2>/dev/null | grep -E 'maas-|rhoai-platform-ops|observability-' || true)
  if [[ -n "$apps" ]]; then
    warn "ArgoCD applications still present: $apps"
    failed=1
  else
    log "  ArgoCD apps -- gone"
  fi

  if (( failed )); then
    warn "Some resources remain. Re-run or clean up manually."
  else
    log "  All resources verified clean."
  fi
}

# ============================================================
# Add new module cleanup functions above this line.
# Then add the function call to main() below.
# ============================================================

cleanup_maas() {
  cleanup_maas_models
  cleanup_maas_platform
  cleanup_maas_operators
}

main() {
  log "Starting cluster cleanup (DRY_RUN=$DRY_RUN)"

  if ! $OC whoami &>/dev/null; then
    echo "ERROR: Not logged in to cluster. Run 'oc login' first." >&2
    exit 1
  fi

  confirm_or_exit

  cleanup_helm_releases

  if [[ -n "$MODULE" ]]; then
    case "$MODULE" in
      maas)
        cleanup_argocd
        cleanup_maas
        ;;
      observability)
        cleanup_argocd
        cleanup_observability
        ;;
      *)
        echo "ERROR: Unknown module '$MODULE'. Available: maas, observability" >&2
        exit 1
        ;;
    esac
  else
    cleanup_argocd
    cleanup_observability
    cleanup_maas
  fi

  verify_cleanup

  log ""
  log "=== Cleanup complete ==="
  if [[ "$DRY_RUN" == "true" ]]; then
    log "(dry-run mode -- no resources were actually deleted)"
  fi
}

main
