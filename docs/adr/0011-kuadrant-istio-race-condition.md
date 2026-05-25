# ADR-0011: Kuadrant/Istio Race Condition Self-Healing

## Status
Accepted

## Context

When deploying via ArgoCD sync waves, wave 0 installs the RHCL (Red Hat Connectivity Link) operator which pulls in both Kuadrant and Service Mesh 3 (Istio). A race condition occurs when the Kuadrant controller starts reconciling before Istio's control plane is fully ready. Kuadrant checks for a Gateway API provider at startup; if it doesn't find one, it marks all AuthPolicies and TokenRateLimitPolicies as `Accepted: False` with reason `MissingDependency`.

This leaves the API governance layer silently broken:
- AuthPolicies don't inject `X-MaaS-Username` headers
- MaaS API returns 500 on API key creation
- MaaS Subscriptions degrade to `Degraded` phase
- ArgoCD reports everything Synced+Healthy (the operator pod IS running)

The condition persists until the Kuadrant operator pod is manually restarted.

## Options Considered

### Option 1: Sync Wave Ordering
- **Pros:** Declarative, no imperative logic
- **Cons:** Not possible — Kuadrant and Istio are installed by the same operator subscription chain (RHCL depends on Service Mesh 3). Both are in wave 0; splitting them would require fundamentally restructuring the operator installation.

### Option 2: Makefile wait-healthy Check
- **Pros:** Simple shell logic in the bootstrap target
- **Cons:** Only helps `make bootstrap-argocd` workflows. Pure ArgoCD deployments (app-of-apps applied directly) never run the Makefile.

### Option 3: PostSync Job in authorino-tls-job (chosen)
- **Pros:** Runs on every ArgoCD sync of `maas-platform`; self-healing; reuses existing Job infrastructure; no new resources needed (just extended RBAC)
- **Cons:** Adds ~1s overhead on normal syncs (one `oc get authpolicy` call that short-circuits); up to 3min delay on first deploy if race condition is hit

## Decision

Integrate the health check as **Step 0** of the existing `authorino-tls-setup` PostSync Job in `maas-platform`. The logic:

1. Query AuthPolicies in `models-as-a-service` for `Accepted` condition
2. If all are Accepted → skip (no-op, ~1s)
3. If reason is `MissingDependency` → restart the Kuadrant operator pod in `redhat-connectivity-link`
4. Wait up to 3 minutes for AuthPolicies to become Accepted
5. Continue with existing TLS setup steps (which now benefit from a healthy Kuadrant)

This runs BEFORE the Authorino TLS steps because the TLS configuration also depends on Kuadrant properly detecting the Gateway API provider.

## Consequences

### Positive
- Self-healing: works for both ArgoCD-only and Makefile-based deployments
- Idempotent: no-op on subsequent syncs once the condition is resolved
- No new Jobs or ServiceAccounts — minimal footprint increase
- First deploy "just works" without manual intervention

### Negative
- First deploy adds up to 3min wait if the race condition is hit
- Requires a ClusterRole (cross-namespace pod delete in `redhat-connectivity-link`)
- Workaround may become unnecessary if RHCL fixes the startup detection upstream

## References
- [RHCL Documentation](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/)
- [Kuadrant MissingDependency issue](https://github.com/Kuadrant/kuadrant-operator/issues) — known behavior when Gateway API provider not detected at startup
- Related: [ADR-0004](0004-tracing-stack.md) (tracing stack depends on same Service Mesh 3 operator)
