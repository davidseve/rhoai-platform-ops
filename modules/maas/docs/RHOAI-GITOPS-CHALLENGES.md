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
| observability-grafana | Grafana | /spec/version | Grafana operator injects the resolved image digest into `spec.version` after creation. This value changes with each operator release and cannot be hardcoded in the template. |

**Key takeaway**: `ServerSideApply` (enabled as a syncOption) handles most operator-mutated fields correctly. The two remaining cases are a CRD version conversion issue (DSCI) and an operator-injected field (Grafana image digest).

## Real GitOps Friction Point: AuthPolicy

The one genuine conflict is the `AuthPolicy` created by `odh-model-controller`. See [ARCHITECTURE.md](ARCHITECTURE.md#authpolicy-conflict-odh-model-controller) for the full explanation. In short:

- When an `LLMInferenceService` is deployed, the controller automatically creates `maas-default-gateway-authn` AuthPolicy
- This basic AuthPolicy overrides our governance AuthPolicy (tier resolution, SAR authorization, response metadata)
- Deleting it doesn't work — the controller recreates it within seconds
- The `opendatahub.io/managed: "false"` annotation is ignored in RHOAI 3.3.1

**Workaround**: A PostSync hook patches the controller's AuthPolicy with our governance logic after every ArgoCD sync. This is the only place where we truly fight the operator.

## Open Questions

- **Do we need to manage DSCInitialization?** The only reason we declare `dsci.yaml` is to set `serviceMesh: Removed` (prevents conflict with Kuadrant's Istio). If a future RHOAI version defaults to `serviceMesh: Removed`, or if the operator's default DSCI works for our setup, we could stop managing it entirely — which would also eliminate the `ignoreDifferences` on `/spec` and the `RespectIgnoreDifferences` sync option from `maas-platform`.

## Version Notes

| RHOAI Version | DSCI/DSC/Dashboard | AuthPolicy conflict |
| ------------- | ------------------ | ------------------- |
| 3.3.1         | Works fine via Helm + 1 ignoreDifferences (DSCI /spec) | PostSync hook required |
| 3.4 (expected)| No changes expected | `maas-controller` may handle AuthPolicy properly |
