---
description: "Remove all resources deployed by this project from the cluster. Works for both ArgoCD and Helm deployments. Handles stuck finalizers and namespaces."
user_invocable: true
---

# Cluster Cleanup

Remove all resources deployed by rhoai-platform-ops from the cluster.

**Works for both deployment modes** (ArgoCD and Helm).

## Script Location

`scripts/cluster-cleanup.sh`

## How It Works

Deletes resources in **reverse deployment order** (wave 2 → 1 → 0):

1. **Helm releases** -- `helm uninstall` all known releases
2. **ArgoCD apps** -- Remove app-of-apps + child Applications
3. **Models** (wave 2) -- LLMInferenceService, RateLimitPolicy, RBAC, hook resources
4. **Platform** (wave 1) -- Gateway, DSC, DSCI, monitoring resources
5. **Operators** (wave 0) -- Subscriptions, CSVs, OperatorGroups, namespaces
6. **Verification** -- Checks all namespaces and ArgoCD apps are gone

Features:
- Confirmation prompt (skip with `--yes`)
- Selective cleanup: pass a module name
- Stuck finalizers handling
- Stuck namespaces handling
- Dry-run mode (`DRY_RUN=true`)
- Configurable timeout (`WAIT_TIMEOUT=180`)

## Running

```bash
make cluster-cleanup              # Full cleanup (skip confirmation)
make cluster-cleanup-maas         # Clean only MaaS
make cluster-cleanup-observability # Clean only observability
make cluster-cleanup-dry          # Dry-run
```

## When to Update

Update `scripts/cluster-cleanup.sh` whenever:
- A new module is added
- A module creates new namespaces or CRDs
- A module adds resources with finalizers
- Operator subscriptions change
