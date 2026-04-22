---
description: Clean up all resources deployed by this project from the cluster. Works regardless of whether the deployment was done via ArgoCD or Helm. Removes Helm releases, ArgoCD apps, module resources, operators, and namespaces in reverse deployment order.
user_invocable: true
---

# Cluster Cleanup

Remove all resources deployed by rhoai-platform-ops from the cluster.

**Works for both deployment modes** (ArgoCD and Helm). The script detects and
cleans whichever was used -- safe to run even when unsure how it was deployed.

## Script Location

`scripts/cluster-cleanup.sh`

## How It Works

The script deletes resources in **reverse deployment order** (wave 2 -> 1 -> 0):

1. **Helm releases** -- `helm uninstall` all known releases (no-op if deployed via ArgoCD)
2. **ArgoCD apps** -- Remove app-of-apps + child Applications (no-op if deployed via Helm)
3. **Models** (wave 2) -- LLMInferenceService (finalizers patched first), RateLimitPolicy,
   TokenRateLimitPolicy, RBAC, hook resources (`patch-gateway-authn` SA/Role/RoleBinding/Job
   in `openshift-ingress`), `maas-models` namespace
4. **Platform** (wave 1) -- Route, Gateway, GatewayClass (`openshift-default`),
   TelemetryPolicy, ServiceMonitor, PrometheusRule, Limitador, DSC, DSCI,
   OdhDashboardConfig, tier-to-group-mapping ConfigMap, OpenShift Groups (`tier-*`),
   kuadrant-readiness-check hook resources (SA/ClusterRole/ClusterRoleBinding/Job),
   gateway tier namespaces (`maas-default-gateway-tier-*`)
5. **Operators** (wave 0) -- Kuadrant CR, LeaderWorkerSetOperator CR, Subscriptions,
   CSVs, OperatorGroups, RHOAI-managed namespaces (`redhat-ods-applications`,
   `redhat-ods-monitoring`), operator namespaces (`redhat-ods-operator`,
   `kuadrant-system`, `leader-worker-set`)
6. **Verification** -- Checks all namespaces (including tier and RHOAI namespaces)
   and ArgoCD apps are gone

Each module has a dedicated `cleanup_<module>` function. The script handles:
- **Confirmation prompt**: Asks before deleting (skip with `--yes`)
- **Selective cleanup**: Pass a module name to clean only that module
- **Stuck finalizers**: Patches LLMInferenceService resources that block namespace deletion
- **Stuck namespaces**: Detects Terminating namespaces and clears blocking finalizers
- **Resource-policy: keep**: Groups with `helm.sh/resource-policy: keep` are deleted explicitly
- **Timeouts**: Configurable wait with fallback to force-cleanup
- **Post-cleanup verification**: Confirms all resources are actually gone

## When to Update

**IMPORTANT**: Update `scripts/cluster-cleanup.sh` whenever:
- A new module is added (add a `cleanup_<module>` function + case in main + namespaces to verify)
- A module creates new namespaces or CRDs
- A module adds resources with finalizers
- Operator subscriptions change
- New Helm releases are added (add to `cleanup_helm_releases` loop)

Follow this pattern when adding a new module cleanup function:

```bash
cleanup_<name>() {
  log "=== <Name>: Cleaning up ==="

  # 1. Delete CRs (custom resources) first
  # 2. Delete namespaced resources
  # 3. Delete cluster-scoped resources
  # 4. Delete namespaces (wait + handle stuck)
}
```

Then update four places:
1. Add `cleanup_<name>` function
2. Add case in `main()` for selective cleanup: `<name>) cleanup_<name> ;;`
3. Add namespaces to the `verify_cleanup()` array
4. Add Helm release names to `cleanup_helm_releases()` loop

## Running

```bash
# Full cleanup (all modules, with confirmation prompt)
./scripts/cluster-cleanup.sh

# Full cleanup (skip confirmation)
make cluster-cleanup

# Clean only a specific module
make cluster-cleanup-maas
./scripts/cluster-cleanup.sh maas

# Dry-run (show what would be deleted)
make cluster-cleanup-dry
DRY_RUN=true ./scripts/cluster-cleanup.sh

# Custom namespace wait timeout
WAIT_TIMEOUT=180 ./scripts/cluster-cleanup.sh --yes
```
