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

### DataScienceCluster (DSC)

The DSC controls which RHOAI components are installed. We explicitly set every component to keep only what we need:

- **Managed**: `dashboard`, `kserve`, `modelsAsService`, `llamastackoperator`
- **Removed**: everything else (`ray`, `workbenches`, `trustyai`, `trainer`, `kueue`, etc.)

New RHOAI versions may add components. It's good practice to explicitly declare all components in the template and default new ones to `Removed` in `values.yaml` to avoid installing unwanted resources.

### OdhDashboardConfig

Configures the RHOAI dashboard UI features. We enable `genAiStudio` and `modelAsService`.

## ArgoCD ignoreDifferences

The RHOAI operator adds internal fields (annotations, status, defaulted spec values) to these resources after creation. This is normal operator behavior, but ArgoCD sees it as drift and would sync-loop without `ignoreDifferences`:

```yaml
ignoreDifferences:
  - group: dscinitialization.opendatahub.io
    kind: DSCInitialization
    jsonPointers:
      - /spec
  - group: datasciencecluster.opendatahub.io
    kind: DataScienceCluster
    jsonPointers:
      - /spec/components
  - group: opendatahub.io
    kind: OdhDashboardConfig
    jsonPointers:
      - /spec
```

This tells ArgoCD to ignore operator-added fields. Our desired state (from the Helm templates) is applied correctly on creation and respected by the operator — `ignoreDifferences` only prevents ArgoCD from fighting over fields the operator enriches afterward.

## Real GitOps Friction Point: AuthPolicy

The one genuine conflict is the `AuthPolicy` created by `odh-model-controller`. See [ARCHITECTURE.md](ARCHITECTURE.md#authpolicy-conflict-odh-model-controller) for the full explanation. In short:

- When an `LLMInferenceService` is deployed, the controller automatically creates `maas-default-gateway-authn` AuthPolicy
- This basic AuthPolicy overrides our governance AuthPolicy (tier resolution, SAR authorization, response metadata)
- Deleting it doesn't work — the controller recreates it within seconds
- The `opendatahub.io/managed: "false"` annotation is ignored in RHOAI 3.3.1

**Workaround**: A PostSync hook patches the controller's AuthPolicy with our governance logic after every ArgoCD sync. This is the only place where we truly fight the operator.

## Version Notes

| RHOAI Version | DSCI/DSC/Dashboard | AuthPolicy conflict |
| ------------- | ------------------ | ------------------- |
| 3.3.1         | Works fine via Helm + ignoreDifferences | PostSync hook required |
| 3.4 (expected)| No changes expected | `maas-controller` may handle AuthPolicy properly |
