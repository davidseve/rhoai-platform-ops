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
  if ! $OC get ns "$ns" &>/dev/null; then return 0; fi
  log "Force-cleaning namespace $ns (clearing blocking finalizers)..."

  for resource in $($OC api-resources --verbs=list --namespaced -o name 2>/dev/null); do
    if ! $OC get ns "$ns" &>/dev/null; then break; fi
    for item in $($OC get "$resource" -n "$ns" -o name 2>/dev/null); do
      $OC patch "$item" -n "$ns" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
  done

  if $OC get ns "$ns" &>/dev/null; then
    run "$OC delete ns '$ns' --timeout=30s --ignore-not-found"
  fi
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
  for release in maas-model-fast maas-model maas-platform maas-db maas-operators obs-tracing obs-grafana obs-operators; do
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

  local model_ns="models-as-a-service"
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

  # DataScienceCluster / DSCInitialization can block namespace deletion.
  # Clear finalizers first — if the operator is already gone, the finalizer will never resolve.
  log "Deleting DataScienceCluster and DSCInitialization..."
  for dsc in $($OC get datasciencecluster -o name 2>/dev/null); do
    run "$OC patch '$dsc' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
  done
  run "$OC delete datasciencecluster --all --timeout=60s --ignore-not-found"
  for dsci in $($OC get dscinitialization -o name 2>/dev/null); do
    run "$OC patch '$dsci' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
  done
  run "$OC delete dscinitialization --all --timeout=30s --ignore-not-found"

  # Kuadrant CR must be deleted before its operator namespace
  log "Deleting Kuadrant CR..."
  run "$OC delete kuadrant --all -n '$kuadrant_ns' --timeout=60s --ignore-not-found"

  # LeaderWorkerSetOperator CR
  log "Deleting LeaderWorkerSetOperator CR..."
  run "$OC delete leaderworkersetoperator --all --timeout=60s --ignore-not-found"

  # GatewayClass left behind (cluster-scoped, not always pruned)
  log "Deleting GatewayClasses..."
  run "$OC delete gatewayclass kuadrant-multi-cluster-gateway-instance-per-cluster --ignore-not-found"

  # Gateway tier namespaces (created dynamically by AuthPolicy, not in chart)
  log "Deleting gateway tier namespaces..."
  for ns in $($OC get ns -o name 2>/dev/null | grep 'maas-default-gateway-tier-'); do
    run "$OC delete '$ns' --timeout=60s --ignore-not-found"
  done

  # Operator subscriptions / CSVs (in operator namespaces, not chart-managed)
  log "Deleting operator subscriptions and CSVs..."
  for ns in redhat-ods-operator redhat-connectivity-link leader-worker-set; do
    run "$OC delete subscription --all -n '$ns' --ignore-not-found"
    run "$OC delete csv --all -n '$ns' --ignore-not-found"
    run "$OC delete operatorgroup --all -n '$ns' --ignore-not-found"
  done
  # Legacy: RHCL may have been installed in openshift-operators (pre-dedicated-namespace).
  # Clean up any residual subscriptions/CSVs there too.
  local rhcl_subs="rhcl-operator authorino-operator limitador-operator dns-operator"
  for sub in $rhcl_subs; do
    for s in $($OC get subscription -n openshift-operators -o name 2>/dev/null | grep "subscription.operators.coreos.com/${sub}" || true); do
      run "$OC delete '$s' -n openshift-operators --ignore-not-found"
    done
  done
  local rhcl_csv_patterns="rhcl authorino limitador dns-operator"
  for pat in $rhcl_csv_patterns; do
    for csv in $($OC get csv -n openshift-operators -o name 2>/dev/null | grep "$pat" || true); do
      run "$OC delete '$csv' -n openshift-operators --ignore-not-found"
    done
  done

  # Namespaces
  log "Deleting namespaces..."
  for ns in "$model_ns" redhat-ods-applications redhat-ods-monitoring \
            redhat-ods-operator redhat-connectivity-link "$kuadrant_ns" leader-worker-set; do
    run "$OC delete ns '$ns' --timeout=60s --ignore-not-found"
  done

  # Wait for namespace termination (parallel)
  for ns in "$model_ns" redhat-ods-applications redhat-ods-monitoring \
            redhat-ods-operator redhat-connectivity-link "$kuadrant_ns" leader-worker-set; do
    wait_ns_gone "$ns" 120 &
  done
  for ns in $($OC get ns -o name 2>/dev/null | grep 'maas-default-gateway-tier-' | sed 's|namespace/||'); do
    wait_ns_gone "$ns" 60 &
  done
  wait
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

  # Operator subscriptions / CSVs in operator namespaces
  for ns in openshift-grafana-operator openshift-opentelemetry-operator openshift-tempo-operator; do
    run "$OC delete subscription --all -n '$ns' --ignore-not-found"
    run "$OC delete csv --all -n '$ns' --ignore-not-found"
    run "$OC delete operatorgroup --all -n '$ns' --ignore-not-found"
  done

  # Cluster-scoped RBAC
  run "$OC delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found"
  run "$OC delete clusterrole grafana-proxy-observability --ignore-not-found"

  # Namespaces
  for ns in observability openshift-grafana-operator openshift-opentelemetry-operator openshift-tempo-operator; do
    run "$OC delete ns '$ns' --timeout=60s --ignore-not-found"
  done
  for ns in observability openshift-grafana-operator openshift-opentelemetry-operator openshift-tempo-operator; do
    wait_ns_gone "$ns" 90 &
  done
  wait
}

# ============================================================
# ArgoCD
# ============================================================

ARGOCD_CORE_FLAGS="--core"
ARGOCD_NS="${ARGOCD_NS:-openshift-gitops}"

argocd_core() {
  $ARGOCD "$@" $ARGOCD_CORE_FLAGS
}

wait_argocd_app_gone() {
  local app="$1"
  local timeout="${2:-120}"
  if [[ "$DRY_RUN" == "true" ]]; then return 0; fi
  local elapsed=0
  while $OC get application "$app" -n "$ARGOCD_NS" &>/dev/null; do
    if (( elapsed >= timeout )); then
      warn "ArgoCD app $app still exists after ${timeout}s -- removing finalizer"
      $OC patch application "$app" -n "$ARGOCD_NS" \
        --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      sleep 5
      if $OC get application "$app" -n "$ARGOCD_NS" &>/dev/null; then
        warn "ArgoCD app $app still exists after finalizer removal -- forcing delete"
        $OC delete application "$app" -n "$ARGOCD_NS" --force --grace-period=0 2>/dev/null || true
      fi
      return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
}

delete_apps_and_wait() {
  local wave_label="$1"; shift
  local apps=("$@")
  log "Deleting $wave_label apps: ${apps[*]}"
  for app in "${apps[@]}"; do
    if $OC get application "$app" -n "$ARGOCD_NS" &>/dev/null; then
      run "argocd_core app delete '$app' --cascade -y"
    fi
  done
  for app in "${apps[@]}"; do
    wait_argocd_app_gone "$app" 120
  done
}

cleanup_argocd() {
  log "=== Removing ArgoCD Applications ==="

  local prev_ns
  prev_ns=$($OC project -q 2>/dev/null || echo "default")

  if ! command -v "$ARGOCD" &>/dev/null; then
    warn "argocd CLI not found -- falling back to oc delete (no cascade)"
    for app in maas-model-fast maas-model maas-platform maas-db maas-operators \
               observability-tracing observability-grafana observability-operators \
               rhoai-platform-ops; do
      run "$OC delete application '$app' -n '$ARGOCD_NS' --ignore-not-found"
    done
    sleep 10
    return
  fi

  # --core requires the active namespace to be the ArgoCD namespace
  run "$OC project '$ARGOCD_NS'"

  # ArgoCD app-of-apps deletes all child apps simultaneously (sync-waves only
  # control creation order, not deletion order). This causes stuck namespaces
  # because operators (wave 0) are removed before their CRs (wave 2) resolve
  # finalizers. Workaround: disable auto-sync, then delete in reverse wave order.
  # TODO: Replace with PreDelete hooks when OpenShift GitOps ships ArgoCD 3.3+.

  # 1. Disable auto-sync on app-of-apps to prevent child recreation
  log "Disabling auto-sync on app-of-apps..."
  run "argocd_core app set rhoai-platform-ops --sync-policy none"

  # 2. Pre-clean CRs with finalizers BEFORE deleting any apps.
  #    The operators must still be running when we clear these.
  log "Pre-cleaning CRs with finalizers..."
  local model_ns="models-as-a-service"
  if $OC get ns "$model_ns" &>/dev/null; then
    for lis in $($OC get llminferenceservice -n "$model_ns" -o name 2>/dev/null); do
      run "$OC patch '$lis' -n '$model_ns' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    done
    run "$OC delete llminferenceservice --all -n '$model_ns' --timeout=60s --ignore-not-found"
  fi
  for dsc in $($OC get datasciencecluster -o name 2>/dev/null); do
    run "$OC patch '$dsc' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
  done
  for dsci in $($OC get dscinitialization -o name 2>/dev/null); do
    run "$OC patch '$dsci' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
  done

  # 3. Delete child apps in reverse wave order (wave 2 → 1 → 0)
  delete_apps_and_wait "wave 2" maas-model-fast maas-model benchmarks
  delete_apps_and_wait "wave 1" maas-platform maas-db observability-tracing observability-grafana
  delete_apps_and_wait "wave 0" maas-operators observability-operators

  # 4. Delete app-of-apps last
  log "Deleting app-of-apps..."
  run "argocd_core app delete rhoai-platform-ops --cascade -y"
  wait_argocd_app_gone "rhoai-platform-ops" 60

  # Restore previous namespace
  run "$OC project '$prev_ns'"

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
    "models-as-a-service"
    "redhat-ods-applications"
    "redhat-ods-monitoring"
    "redhat-ods-operator"
    "redhat-connectivity-link"
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
  namespaces+=("benchmarks")
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
  apps=$($OC get applications.argoproj.io -n openshift-gitops -o name 2>/dev/null | grep -E 'maas-|rhoai-platform-ops|observability-|benchmarks' || true)
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
# Benchmarks cleanup
# ============================================================
cleanup_benchmarks_residual() {
  log "=== Benchmarks: Cleaning up residual resources ==="
  local ns="benchmarks"

  # 1. Delete benchmark Jobs
  run "$OC delete jobs --all -n '$ns' --timeout=60s --ignore-not-found"

  # 2. Delete PVCs
  run "$OC delete pvc --all -n '$ns' --timeout=60s --ignore-not-found"

  # 3. Delete namespace
  run "$OC delete ns '$ns' --timeout=60s --ignore-not-found"
  wait_ns_gone "$ns" 120
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
      benchmarks)    cleanup_benchmarks_residual ;;
      *)
        echo "ERROR: Unknown module '$MODULE'. Available: maas, observability, benchmarks" >&2
        exit 1
        ;;
    esac
  else
    cleanup_benchmarks_residual
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
