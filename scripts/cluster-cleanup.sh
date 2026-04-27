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
ARGOCD="${ARGOCD:-argocd}"
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
# Helm releases (from helm-first workflow)
# ============================================================
cleanup_helm_releases() {
  log "=== Removing Helm releases (if any) ==="
  if ! command -v helm &>/dev/null; then
    log "  helm not found, skipping Helm release cleanup"
    return 0
  fi
  for release in maas-model-fast maas-model maas-platform maas-operators obs-tracing obs-grafana obs-operators; do
    local status
    status=$(helm status "$release" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 || true)
    if [[ -z "$status" ]]; then continue; fi
    log "  Uninstalling $release ($status)..."
    if ! run "helm uninstall '$release' --wait --timeout 2m"; then
      log "  helm uninstall failed for $release -- force-removing release secrets"
      run "$OC delete secret -n default -l name='$release',owner=helm --ignore-not-found"
    fi
  done
  for secret in $($OC get secret -n default -l owner=helm -o name 2>/dev/null | grep -E 'maas-|rhoai-|obs-' || true); do
    log "  Removing leftover Helm secret: $secret"
    run "$OC delete '$secret' -n default --ignore-not-found"
  done
}

# ============================================================
# Module: MaaS -- residual resources (not managed by ArgoCD)
# ============================================================
cleanup_maas_residual() {
  log "=== MaaS: Cleaning up residual resources ==="

  local model_ns="maas-models"
  local gateway_ns="openshift-ingress"
  local kuadrant_ns="kuadrant-system"

  # LLMInferenceService can have stuck finalizers
  if $OC get ns "$model_ns" &>/dev/null; then
    log "Clearing LLMInferenceService finalizers..."
    for lis in $($OC get llminferenceservice -n "$model_ns" -o name 2>/dev/null); do
      run "$OC patch '$lis' -n '$model_ns' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    done
    run "$OC delete llminferenceservice --all -n '$model_ns' --timeout=60s --ignore-not-found"
  fi

  # DataScienceCluster / DSCInitialization can block namespace deletion
  log "Deleting DataScienceCluster and DSCInitialization..."
  run "$OC delete datasciencecluster --all --timeout=120s --ignore-not-found"
  run "$OC delete dscinitialization --all --timeout=120s --ignore-not-found"

  # Kuadrant CR must be deleted before its operator namespace
  log "Deleting Kuadrant CR..."
  run "$OC delete kuadrant --all -n '$kuadrant_ns' --timeout=60s --ignore-not-found"

  # LeaderWorkerSetOperator CR
  log "Deleting LeaderWorkerSetOperator CR..."
  run "$OC delete leaderworkersetoperator --all --timeout=60s --ignore-not-found"

  # GatewayClass left behind (cluster-scoped, not always pruned)
  log "Deleting GatewayClasses..."
  run "$OC delete gatewayclass openshift-default --ignore-not-found"
  run "$OC delete gatewayclass kuadrant-multi-cluster-gateway-instance-per-cluster --ignore-not-found"

  # Gateway tier namespaces (created dynamically by AuthPolicy, not in chart)
  log "Deleting gateway tier namespaces..."
  for ns in $($OC get ns -o name 2>/dev/null | grep 'maas-default-gateway-tier-'); do
    run "$OC delete '$ns' --timeout=60s --ignore-not-found"
  done

  # Operator subscriptions / CSVs (in operator namespaces, not chart-managed)
  log "Deleting operator subscriptions and CSVs..."
  for ns in redhat-ods-operator kuadrant-system leader-worker-set; do
    run "$OC delete subscription --all -n '$ns' --ignore-not-found"
    run "$OC delete csv --all -n '$ns' --ignore-not-found"
    run "$OC delete operatorgroup --all -n '$ns' --ignore-not-found"
  done

  # Namespaces
  log "Deleting namespaces..."
  for ns in "$model_ns" redhat-ods-applications redhat-ods-monitoring \
            redhat-ods-operator "$kuadrant_ns" leader-worker-set; do
    run "$OC delete ns '$ns' --timeout=60s --ignore-not-found"
  done

  # Wait for namespace termination
  for ns in "$model_ns" redhat-ods-applications redhat-ods-monitoring \
            redhat-ods-operator "$kuadrant_ns" leader-worker-set; do
    wait_ns_gone "$ns" 120
  done

  # Dynamic tier namespaces
  for ns in $($OC get ns -o name 2>/dev/null | grep 'maas-default-gateway-tier-' | sed 's|namespace/||'); do
    wait_ns_gone "$ns" 60
  done
}

# ============================================================
# Module: Observability -- residual resources
# ============================================================
cleanup_observability_residual() {
  log "=== Observability: Cleaning up residual resources ==="

  # CRs with potential finalizers
  log "Deleting tracing CRs..."
  run "$OC delete opentelemetrycollector --all -n observability --ignore-not-found"
  run "$OC delete tempomonolithic --all -n observability --ignore-not-found"

  log "Deleting Grafana CRs..."
  run "$OC delete grafanadashboard --all -A --ignore-not-found"
  run "$OC delete grafanadatasource --all -A --ignore-not-found"
  run "$OC delete grafana --all -n observability --ignore-not-found"

  # Grafana Operator is installed globally (not in a chart-managed namespace)
  log "Deleting Grafana Operator subscription (global)..."
  run "$OC delete subscription grafana-operator -n openshift-operators --ignore-not-found"
  for csv in $($OC get csv -n openshift-operators -o name 2>/dev/null | grep grafana-operator || true); do
    run "$OC delete '$csv' -n openshift-operators --ignore-not-found"
  done

  # Operator subscriptions / CSVs in operator namespaces
  for ns in openshift-opentelemetry-operator openshift-tempo-operator; do
    run "$OC delete subscription --all -n '$ns' --ignore-not-found"
    run "$OC delete csv --all -n '$ns' --ignore-not-found"
    run "$OC delete operatorgroup --all -n '$ns' --ignore-not-found"
  done

  # Cluster-scoped RBAC
  run "$OC delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found"
  run "$OC delete clusterrole grafana-proxy-observability --ignore-not-found"

  # Namespaces
  for ns in observability openshift-opentelemetry-operator openshift-tempo-operator; do
    run "$OC delete ns '$ns' --timeout=60s --ignore-not-found"
  done
  for ns in observability openshift-opentelemetry-operator openshift-tempo-operator; do
    wait_ns_gone "$ns" 90
  done
}

# ============================================================
# ArgoCD
# ============================================================

argocd_login() {
  if [[ "$DRY_RUN" == "true" ]]; then return 0; fi

  local server
  server=$($OC get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -z "$server" ]]; then
    warn "ArgoCD route not found -- falling back to oc delete"
    return 1
  fi

  local password
  password=$($OC get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d || true)

  if $ARGOCD login "$server" --username admin --password "$password" --grpc-web --insecure >/dev/null 2>&1; then
    return 0
  fi

  # ArgoCD on OpenShift: try --sso + oc token
  if $ARGOCD login "$server" --grpc-web --insecure --header "Authorization: Bearer $($OC whoami -t)" >/dev/null 2>&1; then
    return 0
  fi

  warn "ArgoCD login failed -- falling back to oc delete"
  return 1
}

wait_argocd_app_gone() {
  local app="$1"
  local timeout="${2:-120}"
  if [[ "$DRY_RUN" == "true" ]]; then return 0; fi
  local elapsed=0
  while $ARGOCD app get "$app" >/dev/null 2>&1; do
    if (( elapsed >= timeout )); then
      warn "ArgoCD app $app still exists after ${timeout}s"
      return 1
    fi
    sleep 5
    (( elapsed += 5 ))
  done
}

cleanup_argocd() {
  log "=== Removing ArgoCD Applications ==="

  if ! command -v "$ARGOCD" &>/dev/null || ! argocd_login; then
    log "Using oc to delete ArgoCD applications (no cascade)..."
    for app in maas-model-fast maas-model maas-platform maas-operators \
               observability-tracing observability-grafana observability-operators \
               rhoai-platform-ops; do
      run "$OC delete application '$app' -n openshift-gitops --ignore-not-found"
    done
    sleep 10
    return
  fi

  log "Logged into ArgoCD, using cascade delete..."

  # 1. Delete app-of-apps first to stop child recreation
  log "Deleting app-of-apps (cascade)..."
  run "$ARGOCD app delete rhoai-platform-ops --cascade --grpc-web -y"
  wait_argocd_app_gone "rhoai-platform-ops" 30

  # 2. Delete child apps with cascade -- ArgoCD will remove managed resources
  local apps=(
    maas-model-fast maas-model maas-platform maas-operators
    observability-tracing observability-grafana observability-operators
  )
  for app in "${apps[@]}"; do
    if $ARGOCD app get "$app" >/dev/null 2>&1; then
      log "  Deleting $app (cascade)..."
      run "$ARGOCD app delete '$app' --cascade --grpc-web -y"
    fi
  done

  # 3. Wait for all apps to terminate
  for app in "${apps[@]}"; do
    wait_argocd_app_gone "$app" 120
  done

  log "All ArgoCD applications removed."
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
    "openshift-opentelemetry-operator"
    "openshift-tempo-operator"
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

main() {
  log "Starting cluster cleanup (DRY_RUN=$DRY_RUN)"

  if ! $OC whoami &>/dev/null; then
    echo "ERROR: Not logged in to cluster. Run 'oc login' first." >&2
    exit 1
  fi

  confirm_or_exit

  # 1. Remove Helm releases (if any from helm-first workflow)
  cleanup_helm_releases

  # 2. Delete ArgoCD applications (cascade removes chart-managed resources)
  cleanup_argocd

  # 3. Clean residual resources not managed by ArgoCD charts
  if [[ -n "$MODULE" ]]; then
    case "$MODULE" in
      maas)          cleanup_maas_residual ;;
      observability) cleanup_observability_residual ;;
      *)
        echo "ERROR: Unknown module '$MODULE'. Available: maas, observability" >&2
        exit 1
        ;;
    esac
  else
    cleanup_observability_residual
    cleanup_maas_residual
  fi

  verify_cleanup

  log ""
  log "=== Cleanup complete ==="
  if [[ "$DRY_RUN" == "true" ]]; then
    log "(dry-run mode -- no resources were actually deleted)"
  fi
}

main
