# RHOAI and GitOps — Notes

RHOAI (Red Hat OpenShift AI) uses an operator-managed model where controllers reconcile resources. This works well with GitOps in general, but requires understanding a few patterns.

## Managed Resources

### DSCInitialization (DSCI)

We declare the DSCI in our Helm chart to control how RHOAI initializes its environment:

```yaml
spec:
  serviceMesh:
    managementState: Removed    # Kuadrant brings its own Istio
  monitoring:
    managementState: Managed    # Enables redhat-ods-monitoring namespace
  trustedCABundle:
    managementState: Managed    # CA injection for TLS between components
```

The key setting is `serviceMesh: Removed` — without it, RHOAI installs its own Istio, which conflicts with the Istio that Kuadrant deploys via Service Mesh 3.

**Important**: The DSCI CRD has two served versions (v1 storage=false, v2 storage=true). The template must use `apiVersion: dscinitialization.opendatahub.io/v2` and include operator-defaulted fields (`monitoring.metrics: {}`, `trustedCABundle.customCABundle: ""`) to minimize drift. Even so, the v1/v2 conversion layer can cause ArgoCD to report OutOfSync, requiring `ignoreDifferences` on `/spec`.

### DataScienceCluster (DSC)

The DSC controls which RHOAI components are installed. We explicitly set every component to keep only what we need:

- **Managed**: `dashboard`, `kserve`, `modelsAsService`, `llamastackoperator`
- **Removed**: everything else (`ray`, `workbenches`, `trustyai`, `trainer`, `kueue`, etc.)

New RHOAI versions may add components. It's good practice to explicitly declare all components in the template and default new ones to `Removed` in `values.yaml` to avoid installing unwanted resources.

### OdhDashboardConfig

Configures the RHOAI dashboard UI features. We enable `genAiStudio` and `modelAsService`.

## ArgoCD ignoreDifferences — Audit Results

We performed a fresh-cluster audit (April 2026) removing all `ignoreDifferences` entries and validating one by one which cause actual sync-loops. Results:

### Unnecessary (removed) — 8 of 10 rules

| App | Resource | jsonPointers | Why unnecessary |
|-----|----------|-------------|-----------------|
| maas-operators | Subscription | /spec/startingCSV, /status | ServerSideApply handles OLM mutations |
| maas-operators | OperatorGroup | /metadata/annotations | No drift observed |
| maas-platform | DataScienceCluster | /spec/components | No drift with ServerSideApply |
| maas-platform | OdhDashboardConfig | /spec | No drift with ServerSideApply |
| maas-platform | Gateway | /metadata/annotations | No drift observed |
| maas-model(s) | LLMInferenceService | /metadata/annotations, /spec | No drift observed |
| observability-operators | Subscription | /spec/startingCSV, /status | Same as maas-operators |
| observability-tracing | TempoMonolithic, OTelCollector | /spec | No drift observed |

### Necessary (kept, narrowed) — 2 rules

| App | Resource | jsonPointers | Why necessary |
|-----|----------|-------------|---------------|
| maas-platform | DSCInitialization | /spec | CRD v1/v2 conversion layer causes ArgoCD drift even when spec matches live state. Template uses v2 with operator defaults to minimize drift, but the conversion still triggers OutOfSync. **TODO**: investigate whether we actually need to manage DSCI ourselves — if the operator creates a suitable default DSCI, we could stop declaring it and remove this ignoreDifferences entirely. |
| observability-grafana | Grafana | /spec/version | Grafana operator injects the resolved image digest into `spec.version` after creation. This value changes with each operator release and cannot be hardcoded in the template. **TODO**: this goes away if we migrate from community Grafana Operator to COO/Perses (see ADR-0003). |

**Key takeaway**: `ServerSideApply` (enabled as a syncOption) handles most operator-mutated fields correctly. The two remaining cases are a CRD version conversion issue (DSCI) and an operator-injected field (Grafana image digest).

## AuthPolicy Management

### RHOAI 3.3.1: PostSync hook required

The one genuine conflict was the `AuthPolicy` created by `odh-model-controller`. The `opendatahub.io/managed: "false"` annotation was ignored. A PostSync hook (`cleanup-authn-hook.yaml`) patched the controller's AuthPolicy with governance logic.

### RHOAI 3.4 EA2: Hooks no longer needed

In 3.4, two key changes eliminate the hook:

1. **`opendatahub.io/managed: "false"` works** — prevents `odh-model-controller` from overriding AuthPolicies
2. **`maas-controller`** manages AuthPolicies and TokenRateLimitPolicies via MaaSSubscription CRs

Both PostSync hooks (`cleanup-authn-hook`, `kuadrant-readiness-hook`) are disabled via `hooks.*.enabled: false` in values. See [ADR-0005](../../../docs/adr/0005-maas-subscription-model.md).

## Open Questions

- **Do we need to manage DSCInitialization?** The only reason we declare `dsci.yaml` is to set `serviceMesh: Removed` (prevents conflict with Kuadrant's Istio). If a future RHOAI version defaults to `serviceMesh: Removed`, or if the operator's default DSCI works for our setup, we could stop managing it entirely — which would also eliminate the `ignoreDifferences` on `/spec` and the `RespectIgnoreDifferences` sync option from `maas-platform`.
- **Migrate from community Grafana Operator to COO/Perses?** The `ignoreDifferences` on Grafana `/spec/version` exists because the community operator injects the image digest. Migrating to Red Hat's Cluster Observability Operator (COO) with Perses dashboards (see [ADR-0003](../../../docs/adr/0003-grafana-operator.md)) would eliminate this rule and reduce community dependencies.

## Version Notes

| RHOAI Version | DSCI/DSC/Dashboard | AuthPolicy conflict |
| ------------- | ------------------ | ------------------- |
| 3.3.1         | Works fine via Helm + 1 ignoreDifferences (DSCI /spec) | PostSync hook required |
| 3.4 EA2       | `rawDeploymentServiceConfig: Headed`, `sparkoperator`, `kserve.wva` added to DSC. `maas-controller` auto-creates Tenant, AuthPolicies, TokenRateLimitPolicies. Models in `models-as-a-service` namespace. MaaSSubscription replaces per-tier rate limits. | **Resolved**: both hooks disabled. `opendatahub.io/managed: "false"` works. Token rate limits don't fire (EA2 bug, [fixed upstream](https://github.com/opendatahub-io/models-as-a-service/pull/543)). |
